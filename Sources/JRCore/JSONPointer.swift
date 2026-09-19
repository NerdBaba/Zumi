import Foundation

// MARK: - JSON Pointer (RFC 6901)

public enum PointerError: Error, Sendable, Equatable {
    case invalidFormat
    case missingKey(String)
    case indexOutOfBounds(Int)
    case notIndexable
}

public func splitPointer(_ pointer: String) -> [String]? {
    guard pointer.hasPrefix("/") || pointer.isEmpty else { return nil }
    if pointer.isEmpty { return [] }
    return pointer.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map {
        $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
    }
}

public func getByPath(_ root: JSONValue, _ pointer: String) -> JSONValue? {
    guard let tokens = splitPointer(pointer) else { return nil }
    var cur = root
    for tok in tokens {
        switch cur {
        case .object(let o):
            guard let next = o[tok] else { return nil }
            cur = next
        case .array(let a):
            guard let idx = Int(tok), idx >= 0, idx < a.count else { return nil }
            cur = a[idx]
        default: return nil
        }
    }
    return cur
}

public func getByPath(_ dict: [String: JSONValue], _ pointer: String) -> JSONValue? {
    getByPath(.object(dict), pointer)
}

public func setByPath(_ root: inout JSONValue, _ pointer: String, _ value: JSONValue) -> Bool {
    guard let tokens = splitPointer(pointer) else { return false }
    if tokens.isEmpty { root = value; return true }
    return setRec(&root, tokens, value)
}

private func setRec(_ node: inout JSONValue, _ tokens: [String], _ value: JSONValue) -> Bool {
    let head = tokens[0]
    if tokens.count == 1 {
        switch node {
        case .object(var o):
            o[head] = value; node = .object(o); return true
        case .array(var a):
            if head == "-" { a.append(value); node = .array(a); return true }
            guard let idx = Int(head), idx >= 0, idx <= a.count else { return false }
            if idx == a.count { a.append(value) } else { a[idx] = value }
            node = .array(a); return true
        default: return false
        }
    }
    switch node {
    case .object(var o):
        var child = o[head] ?? .object([:])
        guard setRec(&child, Array(tokens.dropFirst()), value) else { return false }
        o[head] = child; node = .object(o); return true
    case .array(var a):
        guard let idx = Int(head), idx >= 0, idx < a.count else { return false }
        guard setRec(&a[idx], Array(tokens.dropFirst()), value) else { return false }
        node = .array(a); return true
    default: return false
    }
}

public func removeByPath(_ root: inout JSONValue, _ pointer: String) -> Bool {
    guard let tokens = splitPointer(pointer), !tokens.isEmpty else { return false }
    return removeRec(&root, tokens)
}

private func removeRec(_ node: inout JSONValue, _ tokens: [String]) -> Bool {
    let head = tokens[0]
    if tokens.count == 1 {
        switch node {
        case .object(var o):
            guard o[head] != nil else { return false }
            o.removeValue(forKey: head); node = .object(o); return true
        case .array(var a):
            guard let idx = Int(head), idx >= 0, idx < a.count else { return false }
            a.remove(at: idx); node = .array(a); return true
        default: return false
        }
    }
    switch node {
    case .object(var o):
        guard var child = o[head] else { return false }
        guard removeRec(&child, Array(tokens.dropFirst())) else { return false }
        o[head] = child; node = .object(o); return true
    case .array(var a):
        guard let idx = Int(head), idx >= 0, idx < a.count else { return false }
        guard removeRec(&a[idx], Array(tokens.dropFirst())) else { return false }
        node = .array(a); return true
    default: return false
    }
}

// Flatten to leaf pointers (devtools parity)
public func flattenToPointers(_ value: JSONValue, base: String = "") -> [(path: String, value: JSONValue)] {
    switch value {
    case .object(let o):
        if o.isEmpty { return [(base.isEmpty ? "/" : base, value)] }
        return o.flatMap { k, v in
            let esc = k.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
            return flattenToPointers(v, base: base + "/" + esc)
        }
    case .array(let a):
        if a.isEmpty { return [(base.isEmpty ? "/" : base, value)] }
        return a.enumerated().flatMap { i, v in flattenToPointers(v, base: "\(base)/\(i)") }
    default:
        return [(base.isEmpty ? "/" : base, value)]
    }
}
