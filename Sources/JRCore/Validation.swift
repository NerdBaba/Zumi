import Foundation

// MARK: - Validation engine (json-render parity)

public struct ValidationCheck: Codable, Sendable, Equatable {
    public var type: String
    public var args: [String: JSONValue]?
    public var message: String
}

public typealias ValidationFunction = @Sendable (JSONValue, [String: JSONValue]) -> Bool

public let builtinValidators: [String: ValidationFunction] = [
    "required": { v, _ in
        switch v { case .null: return false; case .string(let s): return !s.isEmpty; case .array(let a): return !a.isEmpty; default: return true }
    },
    "email": { v, _ in guard case let .string(s) = v else { return false }; return s.contains("@") && s.contains(".") },
    "minLength": { v, a in guard case let .string(s) = v, let m = a["min"]?.intValue ?? a["length"]?.intValue else { return false }; return s.count >= m },
    "maxLength": { v, a in guard case let .string(s) = v, let m = a["max"]?.intValue ?? a["length"]?.intValue else { return false }; return s.count <= m },
    "pattern": { v, a in guard case let .string(s) = v, let p = a["pattern"]?.stringValue, let re = try? NSRegularExpression(pattern: p) else { return false }; return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil },
    "min": { v, a in guard let x = v.doubleValue, let m = a["min"]?.doubleValue else { return false }; return x >= m },
    "max": { v, a in guard let x = v.doubleValue, let m = a["max"]?.doubleValue else { return false }; return x <= m },
    "numeric": { v, _ in v.doubleValue != nil },
    "url": { v, _ in guard case let .string(s) = v, let u = URL(string: s) else { return false }; return u.scheme != nil },
    "matches": { v, a in guard let o = a["other"] else { return false }; return v == o },
    "equalTo": { v, a in guard let o = a["other"] else { return false }; return v == o },
    "lessThan": { v, a in guard let x = v.doubleValue, let o = a["other"]?.doubleValue else { return false }; return x < o },
    "greaterThan": { v, a in guard let x = v.doubleValue, let o = a["other"]?.doubleValue else { return false }; return x > o },
    "requiredIf": { v, a in
        guard let f = a["field"] else { return true }
        let truthy: Bool
        switch f { case .bool(let b): truthy = b; case .null: truthy = false; case .string(let s): truthy = !s.isEmpty; default: truthy = true }
        if !truthy { return true }
        switch v { case .null: return false; case .string(let s): return !s.isEmpty; default: return true }
    },
]

public func validateField(value: JSONValue, checks: [ValidationCheck], custom: [String: ValidationFunction] = [:], state: [String: JSONValue] = [:]) -> [String] {
    var errors: [String] = []
    for c in checks {
        // Resolve $state refs inside args (cross-field)
        var args = c.args ?? [:]
        for (k, v) in args {
            if case let .object(d) = v, let s = d["$state"], case let .string(p) = s {
                args[k] = getByPath(state, p) ?? .null
            }
        }
        let fn = custom[c.type] ?? builtinValidators[c.type]
        guard let fn else { errors.append("Unknown validator '\(c.type)'"); continue }
        if !fn(value, args) { errors.append(c.message) }
    }
    return errors
}

public func checksFromProp(_ v: JSONValue) -> [ValidationCheck] {
    guard case let .array(arr) = v else { return [] }
    let data = try? JSONEncoder().encode(arr)
    return (data.flatMap { try? JSONDecoder().decode([ValidationCheck].self, from: $0) }) ?? []
}
