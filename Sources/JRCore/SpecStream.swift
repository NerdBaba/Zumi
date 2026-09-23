import Foundation

// MARK: - SpecStream (JSONL RFC6902)

public struct SpecPatch: Codable, Sendable, Equatable {
    public var op: String // add, remove, replace, move, copy, test
    public var path: String
    public var value: JSONValue?
    public var from: String?
}

public enum SpecStreamError: Error, Sendable {
    case invalidLine(String)
    case patchFailed(String)
}

public func parseSpecStreamLine(_ line: String) -> SpecPatch? {
    let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty, t.hasPrefix("{") else { return nil }
    guard let data = t.data(using: .utf8),
          let p = try? JSONDecoder().decode(SpecPatch.self, from: data) else { return nil }
    return p
}

// Apply patch to Spec object via JSONValue round-trip (mutates in place semantics)
public func applySpecPatch(_ spec: inout Spec, _ patch: SpecPatch) -> Bool {
    guard var root = try? JSONEncoder().encode(spec),
          var obj = try? JSONDecoder().decode(JSONValue.self, from: root) else { return false }
    // Spec JSON keys: root, elements, state — map pointer directly
    guard applyJSONPatch(&obj, patch) else { return false }
    guard let data = try? JSONEncoder().encode(obj),
          let out = try? JSONDecoder().decode(Spec.self, from: data) else { return false }
    spec = out
    return true
}

func applyJSONPatch(_ root: inout JSONValue, _ patch: SpecPatch) -> Bool {
    var candidate = root
    guard applyJSONPatchInPlace(&candidate, patch) else { return false }
    root = candidate
    return true
}

private func applyJSONPatchInPlace(_ root: inout JSONValue, _ patch: SpecPatch) -> Bool {
    switch patch.op {
    case "add":
        guard let value = patch.value else { return false }
        return addByPath(&root, patch.path, value)
    case "replace":
        guard let value = patch.value, getByPath(root, patch.path) != nil else { return false }
        return setByPath(&root, patch.path, value)
    case "remove":
        return removeByPath(&root, patch.path)
    case "move":
        guard let from = patch.from,
              let sourceTokens = splitPointer(from),
              let destinationTokens = splitPointer(patch.path),
              let value = getByPath(root, from) else { return false }
        if sourceTokens == destinationTokens { return true }
        guard !(destinationTokens.count > sourceTokens.count
                && destinationTokens.starts(with: sourceTokens)) else { return false }
        guard removeByPath(&root, from) else { return false }
        return addByPath(&root, patch.path, value)
    case "copy":
        guard let from = patch.from, let value = getByPath(root, from) else { return false }
        return addByPath(&root, patch.path, value)
    case "test":
        guard let value = patch.value else { return false }
        return getByPath(root, patch.path) == value
    default:
        return false
    }
}

public func compileSpecStream(_ jsonl: String) -> Spec {
    var spec = Spec()
    for line in jsonl.split(separator: "\n") {
        if let p = parseSpecStreamLine(String(line)) { _ = applySpecPatch(&spec, p) }
    }
    return spec
}

public final class SpecStreamCompiler: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private var spec = Spec()
    private var patches: [SpecPatch] = []

    public init() {}
    public func push(_ chunk: String) -> (result: Spec, newPatches: [SpecPatch]) {
        lock.lock(); defer { lock.unlock() }
        buffer += chunk
        var fresh: [SpecPatch] = []
        while let nl = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<nl])
            buffer = String(buffer[buffer.index(after: nl)...])
            if let p = parseSpecStreamLine(line) {
                if applySpecPatch(&spec, p) { fresh.append(p); patches.append(p) }
            }
        }
        // Handle trailing complete line without newline on flush only; keep partial in buffer
        return (spec, fresh)
    }
    public func getResult() -> Spec { lock.lock(); defer { lock.unlock() }; return spec }
    public func getPatches() -> [SpecPatch] { lock.lock(); defer { lock.unlock() }; return patches }
    public func reset() { lock.lock(); defer { lock.unlock() }; buffer = ""; spec = Spec(); patches = [] }
}

// MARK: - Deep merge (RFC7396) + diff (for edit modes)

public func deepMergeSpec(base: JSONValue, patch: JSONValue) -> JSONValue {
    switch (base, patch) {
    case (.object(let b), .object(let p)):
        var out = b
        for (k, v) in p {
            if case .null = v { out.removeValue(forKey: k) }
            else if let bv = b[k] { out[k] = deepMergeSpec(base: bv, patch: v) }
            else { out[k] = v }
        }
        return .object(out)
    default:
        return patch // arrays replace atomically
    }
}

public func diffToPatches(old: JSONValue, new: JSONValue, basePath: String = "") -> [SpecPatch] {
    if old == new { return [] }
    switch (old, new) {
    case (.object(let o), .object(let n)):
        var patches: [SpecPatch] = []
        for k in o.keys where n[k] == nil {
            patches.append(.init(op: "remove", path: "\(basePath)/\(k)", value: nil, from: nil))
        }
        for (k, v) in n {
            let escapedKey = k.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
            let p = "\(basePath)/\(escapedKey)"
            if let ov = o[k] { patches += diffToPatches(old: ov, new: v, basePath: p) }
            else { patches.append(.init(op: "add", path: p, value: v, from: nil)) }
        }
        return patches
    case (.array, .array):
        return [.init(op: "replace", path: basePath, value: new, from: nil)]
    default:
        return [.init(op: "replace", path: basePath.isEmpty ? "/" : basePath, value: new, from: nil)]
    }
}
