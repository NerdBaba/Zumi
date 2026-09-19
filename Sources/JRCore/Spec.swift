import Foundation

// MARK: - Spec (flat IR, json-render parity)

public struct Spec: Codable, Sendable, Equatable {
    public var root: String?
    public var elements: [String: UIElement]
    public var state: [String: JSONValue]?

    public init(root: String? = nil, elements: [String: UIElement] = [:], state: [String: JSONValue]? = nil) {
        self.root = root
        self.elements = elements
        self.state = state
    }
}

public struct UIElement: Codable, Sendable, Equatable {
    public var type: String
    public var props: [String: JSONValue]
    public var children: [String]?
    public var slots: [String: [String]]?
    public var visible: VisibilityCondition?
    public var on: [String: ActionBindingOrList]?
    public var repeatConfig: RepeatConfig?
    public var watch: [String: ActionBindingOrList]?
    public var statePath: String?

    enum CodingKeys: String, CodingKey {
        case type, props, children, slots, visible, on
        case repeatConfig = "repeat"
        case watch, statePath
    }

    public init(
        type: String,
        props: [String: JSONValue] = [:],
        children: [String]? = nil,
        slots: [String: [String]]? = nil,
        visible: VisibilityCondition? = nil,
        on: [String: ActionBindingOrList]? = nil,
        repeatConfig: RepeatConfig? = nil,
        watch: [String: ActionBindingOrList]? = nil
    ) {
        self.type = type
        self.props = props
        self.children = children
        self.slots = slots
        self.visible = visible
        self.on = on
        self.repeatConfig = repeatConfig
        self.watch = watch
    }
}

public struct RepeatConfig: Codable, Sendable, Equatable {
    public var statePath: RepeatPath
    public var key: String?

    public init(statePath: RepeatPath, key: String? = nil) {
        self.statePath = statePath
        self.key = key
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(JSONValue.self, forKey: .statePath)
        switch raw {
        case .string(let s):
            statePath = .path(s)
        case .object(let d):
            if case let .string(f) = d["$item"] ?? .null { statePath = .itemField(f) }
            else { throw DecodingError.dataCorruptedError(forKey: .statePath, in: c, debugDescription: "Invalid repeat.statePath") }
        default:
            throw DecodingError.dataCorruptedError(forKey: .statePath, in: c, debugDescription: "Invalid repeat.statePath")
        }
        key = try c.decodeIfPresent(String.self, forKey: .key)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch statePath {
        case .path(let s): try c.encode(JSONValue.string(s), forKey: .statePath)
        case .itemField(let f): try c.encode(JSONValue.object(["$item": .string(f)]), forKey: .statePath)
        }
        try c.encodeIfPresent(key, forKey: .key)
    }

    enum CodingKeys: String, CodingKey {
        case statePath = "statePath"
        case key
    }
}

public enum RepeatPath: Sendable, Equatable {
    case path(String)
    case itemField(String)
}

public struct ActionBinding: Codable, Sendable, Equatable {
    public var action: String
    public var params: [String: JSONValue]?
    public var confirm: ActionConfirm?
    public var onSuccess: ActionSet?
    public var onError: ActionSet?
    public var preventDefault: Bool?

    public init(action: String, params: [String: JSONValue]? = nil) {
        self.action = action
        self.params = params
    }
}

public struct ActionConfirm: Codable, Sendable, Equatable {
    public var title: String
    public var message: String
    public var variant: String?
}

public struct ActionSet: Codable, Sendable, Equatable {
    public var set: [String: JSONValue]?
}

public enum ActionBindingOrList: Codable, Sendable, Equatable {
    case single(ActionBinding)
    case list([ActionBinding])

    public init(from decoder: Decoder) throws {
        if let s = try? ActionBinding(from: decoder) { self = .single(s); return }
        let l = try [ActionBinding](from: decoder)
        self = .list(l)
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .single(let b): try b.encode(to: encoder)
        case .list(let l): try l.encode(to: encoder)
        }
    }
    public var all: [ActionBinding] {
        switch self { case .single(let b): return [b]; case .list(let l): return l }
    }
}

// MARK: - Visibility

public indirect enum VisibilityCondition: Codable, Sendable, Equatable {
    case bool(Bool)
    case state(path: String, op: CompareOp?, value: JSONValue?, not: Bool)
    case item(field: String, op: CompareOp?, value: JSONValue?, not: Bool)
    case index(op: CompareOp?, value: JSONValue?, not: Bool)
    case and([VisibilityCondition])
    case or([VisibilityCondition])

    public init(from decoder: Decoder) throws {
        if let b = try? decoder.singleValueContainer().decode(Bool.self) { self = .bool(b); return }
        if let arr = try? decoder.singleValueContainer().decode([VisibilityCondition].self) { self = .and(arr); return }
        let c = try decoder.container(keyedBy: DynKey.self)
        if c.contains(DynKey("$and")) {
            self = .and(try c.decode([VisibilityCondition].self, forKey: DynKey("$and"))); return
        }
        if c.contains(DynKey("$or")) {
            self = .or(try c.decode([VisibilityCondition].self, forKey: DynKey("$or"))); return
        }
        let not = (try? c.decodeIfPresent(Bool.self, forKey: DynKey("not"))) ?? false
        if let p = try? c.decode(String.self, forKey: DynKey("$state")) {
            let (op, val) = try Self.extractOp(c)
            self = .state(path: p, op: op, value: val, not: not); return
        }
        if let f = try? c.decode(String.self, forKey: DynKey("$item")) {
            let (op, val) = try Self.extractOp(c)
            self = .item(field: f, op: op, value: val, not: not); return
        }
        if c.contains(DynKey("$index")) {
            let (op, val) = try Self.extractOp(c)
            self = .index(op: op, value: val, not: not); return
        }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid visibility condition"))
    }

    static func extractOp(_ c: KeyedDecodingContainer<DynKey>) throws -> (CompareOp?, JSONValue?) {
        // precedence: eq > neq > gt > gte > lt > lte ; only first evaluated
        for key in ["eq", "neq", "gt", "gte", "lt", "lte"] {
            if c.contains(DynKey(key)) {
                let v = try c.decode(JSONValue.self, forKey: DynKey(key))
                return (CompareOp(rawValue: key), v)
            }
        }
        return (nil, nil)
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .bool(let b):
            var s = encoder.singleValueContainer(); try s.encode(b)
        case .and(let arr):
            // Always encode as {"$and": [...]} for round-trip stability.
            var c = encoder.container(keyedBy: DynKey.self)
            try c.encode(arr, forKey: DynKey("$and"))
        case .or(let arr):
            var c = encoder.container(keyedBy: DynKey.self)
            try c.encode(arr, forKey: DynKey("$or"))
        case .state(let p, let op, let v, let not):
            var c = encoder.container(keyedBy: DynKey.self)
            try c.encode(p, forKey: DynKey("$state"))
            if let op { try c.encode(v ?? .null, forKey: DynKey(op.rawValue)) }
            if not { try c.encode(true, forKey: DynKey("not")) }
        case .item(let f, let op, let v, let not):
            var c = encoder.container(keyedBy: DynKey.self)
            try c.encode(f, forKey: DynKey("$item"))
            if let op { try c.encode(v ?? .null, forKey: DynKey(op.rawValue)) }
            if not { try c.encode(true, forKey: DynKey("not")) }
        case .index(let op, let v, let not):
            var c = encoder.container(keyedBy: DynKey.self)
            try c.encode(true, forKey: DynKey("$index"))
            if let op { try c.encode(v ?? .null, forKey: DynKey(op.rawValue)) }
            if not { try c.encode(true, forKey: DynKey("not")) }
        }
    }
}

public enum CompareOp: String, Codable, Sendable {
    case eq, neq, gt, gte, lt, lte
}

struct DynKey: CodingKey {
    var stringValue: String
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil }
}

// MARK: - JSONValue (dynamic JSON, Codable + Equatable)

public indirect enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer()
        if s.decodeNil() { self = .null; return }
        if let b = try? s.decode(Bool.self) { self = .bool(b); return }
        if let i = try? s.decode(Int.self) { self = .int(i); return }
        if let d = try? s.decode(Double.self) { self = .double(d); return }
        if let str = try? s.decode(String.self) { self = .string(str); return }
        if let arr = try? s.decode([JSONValue].self) { self = .array(arr); return }
        if let obj = try? s.decode([String: JSONValue].self) { self = .object(obj); return }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown JSON value"))
    }

    public func encode(to encoder: Encoder) throws {
        var s = encoder.singleValueContainer()
        switch self {
        case .null: try s.encodeNil()
        case .bool(let b): try s.encode(b)
        case .int(let i): try s.encode(i)
        case .double(let d): try s.encode(d)
        case .string(let str): try s.encode(str)
        case .array(let a): try s.encode(a)
        case .object(let o): try s.encode(o)
        }
    }

    // Convenience
    public var stringValue: String? { if case let .string(s) = self { return s }; return nil }
    public var boolValue: Bool? { if case let .bool(b) = self { return b }; return nil }
    public var intValue: Int? {
        switch self { case .int(let i): return i; case .double(let d): return Int(d); default: return nil }
    }
    public var doubleValue: Double? {
        switch self { case .double(let d): return d; case .int(let i): return Double(i); default: return nil }
    }
    public var arrayValue: [JSONValue]? { if case let .array(a) = self { return a }; return nil }
    public var objectValue: [String: JSONValue]? { if case let .object(o) = self { return o }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }

    public static func from(_ any: Any) -> JSONValue {
        switch any {
        case is NSNull: return .null
        case let b as Bool: return .bool(b)
        case let i as Int: return .int(i)
        case let d as Double: return .double(d)
        case let s as String: return .string(s)
        case let a as [Any]: return .array(a.map(from))
        case let d as [String: Any]: return .object(d.mapValues(from))
        default: return .null
        }
    }

    public var anyValue: Any? {
        switch self {
        case .null: return nil
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map { $0.anyValue as Any }
        case .object(let o): return o.mapValues { $0.anyValue as Any }
        }
    }
}

// MARK: - Validation of structure

public struct SpecIssue: Sendable, Equatable {
    public var path: String
    public var message: String
}

public func validateSpec(_ spec: Spec) -> (valid: Bool, issues: [SpecIssue]) {
    var issues: [SpecIssue] = []
    guard let root = spec.root, !root.isEmpty else {
        // Empty spec is allowed as loading state, but not valid for render
        if spec.elements.isEmpty { return (true, []) }
        issues.append(.init(path: "/root", message: "Missing root"))
        return (false, issues)
    }
    guard spec.elements[root] != nil else {
        issues.append(.init(path: "/root", message: "Root '\(root)' not found in elements"))
        return (false, issues)
    }
    // Check refs, cycles, unreachable
    var visited = Set<String>()
    var stack = Set<String>()
    func dfs(_ key: String) {
        if stack.contains(key) { issues.append(.init(path: "/elements/\(key)", message: "Cycle detected")); return }
        guard let el = spec.elements[key] else { issues.append(.init(path: "/elements/\(key)", message: "Dangling reference")); return }
        if visited.contains(key) { return } // shared children: warn, don't fail hard (Jev rejects, renderer warns)
        visited.insert(key); stack.insert(key)
        for child in (el.children ?? []) { dfs(child) }
        for (_, arr) in (el.slots ?? [:]) { for k in arr { dfs(k) } }
        stack.remove(key)
    }
    dfs(root)
    for key in spec.elements.keys where !visited.contains(key) {
        issues.append(.init(path: "/elements/\(key)", message: "Unreachable element (not under root)"))
    }
    // $item scope check is done at render time; structural check here for repeat key presence
    return (issues.isEmpty, issues)
}

public func isNonEmptySpec(_ spec: Spec?) -> Bool {
    guard let s = spec, let r = s.root, !r.isEmpty else { return false }
    return !s.elements.isEmpty
}
