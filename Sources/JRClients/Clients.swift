import Foundation
import JRCore

// MARK: - Prompt builders (parity with buildUserPrompt/edit modes)

public enum EditMode: String, Sendable { case patch, merge, diff }

public func buildUserPrompt(prompt: String, currentSpec: Spec? = nil, state: [String: JSONValue]? = nil, editModes: [EditMode] = [.patch], maxLength: Int = 4000) -> String {
    var p = prompt
    if p.count > maxLength { p = String(p.prefix(maxLength)) }
    guard let cur = currentSpec, isNonEmptySpec(cur),
          let data = try? JSONEncoder().encode(cur),
          let json = String(data: data, encoding: .utf8) else {
        if let s = state, let d = try? JSONEncoder().encode(s), let js = String(data: d, encoding: .utf8) {
            return "\(p)\n\nState context:\n\(js)"
        }
        return p
    }
    let modes = editModes.map(\.rawValue).joined(separator: ",")
    var out = "\(p)\n\nEdit existing spec using modes [\(modes)]. Current spec:\n\(json)"
    if let s = state, let d = try? JSONEncoder().encode(s), let js = String(data: d, encoding: .utf8) {
        out += "\n\nState context:\n\(js)"
    }
    return out
}

// MARK: - OpenAI Completions streaming -> SpecStream

public struct OpenAIConfig: Sendable {
    public var apiKey: String
    public var model: String
    public var baseURL: URL
    public init(apiKey: String, model: String = "gpt-4o-mini", baseURL: URL = URL(string: "https://api.openai.com/v1")!) {
        self.apiKey = apiKey; self.model = model; self.baseURL = baseURL
    }
}

public final class OpenAIStreamClient: Sendable {
    public let config: OpenAIConfig
    public init(config: OpenAIConfig) { self.config = config }

    public func stream(system: String, user: String, onPatch: @Sendable @escaping (SpecPatch, Spec) -> Void) async throws -> Spec {
        let url = config.baseURL.appendingPathComponent("chat/completions")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": config.model,
            "stream": true,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, _) = try await URLSession.shared.bytes(for: req)
        let compiler = SpecStreamCompiler()
        var acc = ""
        for try await line in bytes.lines {
            // SSE: data: {...}
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String else { continue }
            acc += content
            // Extract complete lines
            while let nl = acc.firstIndex(of: "\n") {
                let l = String(acc[..<nl])
                acc = String(acc[acc.index(after: nl)...])
                if let p = parseSpecStreamLine(l) {
                    var s = compiler.getResult()
                    if applySpecPatch(&s, p) {
                        _ = compiler.push(l + "\n")
                        onPatch(p, compiler.getResult())
                    }
                }
            }
        }
        // Flush trailing line
        if let p = parseSpecStreamLine(acc) {
            var s = compiler.getResult()
            if applySpecPatch(&s, p) { _ = compiler.push(acc + "\n"); onPatch(p, compiler.getResult()) }
        }
        return compiler.getResult()
    }
}

// MARK: - Jev decision client (snapshots, not patches)

public struct JevCandidate: Codable, Sendable {
    public var id: String
    public var description: String
    public var element: UIElement
    public var root: Bool?
    public var maxUses: Int?
    public var resource: String?
}

public enum JevStopReason: String, Sendable { case finish, limit, unavailable }

public struct JevConfig: Sendable {
    public var apiKey: String
    public var model: String
    public var baseURL: URL
    public init(apiKey: String, model: String = "typesafe-ai/jev", baseURL: URL = URL(string: "https://gateway.example.com")!) {
        self.apiKey = apiKey; self.model = model; self.baseURL = baseURL
    }
}

public final class JevClient: Sendable {
    public let config: JevConfig
    public init(config: JevConfig) { self.config = config }

    /// Minimal compose: sends candidates + prompt to evaluator, expects snapshot spec back.
    /// Full batched/sequential protocol lives server-side; client replaces spec wholesale per step.
    public func compose(catalog: Catalog, candidates: [JevCandidate], prompt: String, initialState: [String: JSONValue] = [:], initialSpec: Spec? = nil, onStep: @Sendable @escaping (Spec) -> Void) async throws -> (spec: Spec?, stop: JevStopReason) {
        let url = config.baseURL.appendingPathComponent("evaluate")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "model": config.model,
            "prompt": prompt,
            "candidates": (try? JSONEncoder().encode(candidates)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [],
            "initialState": (try? JSONEncoder().encode(initialState)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [:],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let specObj = obj["spec"] else {
            return (initialSpec, .unavailable)
        }
        let specData = try JSONSerialization.data(withJSONObject: specObj)
        if let spec = try? JSONDecoder().decode(Spec.self, from: specData) {
            onStep(spec)
            return (spec, .finish)
        }
        return (initialSpec, .unavailable)
    }
}
