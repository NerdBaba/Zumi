import Foundation

// MARK: - Evaluation context

public struct EvalContext: Sendable {
    public var state: [String: JSONValue]
    public var repeatItem: JSONValue?
    public var repeatIndex: Int?
    public var functions: [String: @Sendable ([String: JSONValue]) -> JSONValue]

    public init(state: [String: JSONValue] = [:], repeatItem: JSONValue? = nil, repeatIndex: Int? = nil, functions: [String: @Sendable ([String: JSONValue]) -> JSONValue] = [:]) {
        self.state = state
        self.repeatItem = repeatItem
        self.repeatIndex = repeatIndex
        self.functions = functions
    }
}

// MARK: - Visibility evaluation

public func evaluateVisibility(_ condition: VisibilityCondition?, ctx: EvalContext) -> Bool {
    guard let c = condition else { return true }
    return evalCond(c, ctx: ctx)
}

private func evalCond(_ c: VisibilityCondition, ctx: EvalContext) -> Bool {
    switch c {
    case .bool(let b): return b
    case .and(let arr): return arr.allSatisfy { evalCond($0, ctx: ctx) }
    case .or(let arr): return arr.contains { evalCond($0, ctx: ctx) }
    case .state(let path, let op, let value, let not):
        let actual = getByPath(ctx.state, path)
        let r = compare(actual: actual, op: op, expected: value.map { resolveExpected($0, ctx: ctx) })
        return not ? !r : r
    case .item(let field, let op, let value, let not):
        guard let item = ctx.repeatItem else { return false }
        let actual: JSONValue?
        if field.isEmpty { actual = item } else { actual = item.objectValue?[field] }
        let r = compare(actual: actual, op: op, expected: value.map { resolveExpected($0, ctx: ctx) })
        return not ? !r : r
    case .index(let op, let value, let not):
        guard let idx = ctx.repeatIndex else { return false }
        let actual = JSONValue.int(idx)
        let r = compare(actual: actual, op: op, expected: value.map { resolveExpected($0, ctx: ctx) })
        return not ? !r : r
    }
}

private func resolveExpected(_ v: JSONValue, ctx: EvalContext) -> JSONValue {
    // Comparison values can be literals or {$state:/b}
    if case let .object(d) = v, d.count == 1, let s = d["$state"], case let .string(p) = s {
        return getByPath(ctx.state, p) ?? .null
    }
    return v
}

private func truthy(_ v: JSONValue?) -> Bool {
    guard let v else { return false }
    switch v {
    case .null: return false
    case .bool(let b): return b
    case .int(let i): return i != 0
    case .double(let d): return d != 0
    case .string(let s): return !s.isEmpty
    case .array(let a): return !a.isEmpty
    case .object(let o): return !o.isEmpty
    }
}

private func compare(actual: JSONValue?, op: CompareOp?, expected: JSONValue?) -> Bool {
    guard let op else { return truthy(actual) }
    guard let e = expected else { return false }
    switch op {
    case .eq: return actual == e
    case .neq: return actual != e
    case .gt, .gte, .lt, .lte:
        guard let a = actual?.doubleValue, let b = e.doubleValue else { return false }
        switch op {
        case .gt: return a > b
        case .gte: return a >= b
        case .lt: return a < b
        case .lte: return a <= b
        default: return false
        }
    }
}

// MARK: - Prop value resolution ($state/$item/$index/$cond/$template/$computed)

public struct ResolveResult: Sendable {
    public var value: JSONValue
    public var bindingPath: String? // for $bindState/$bindItem
}

public func resolvePropValue(_ raw: JSONValue, ctx: EvalContext) -> ResolveResult {
    // Binding expressions pass through value but record path
    if case let .object(d) = raw {
        if let b = d["$bindState"], case let .string(p) = b {
            let v = getByPath(ctx.state, p) ?? .null
            return ResolveResult(value: v, bindingPath: p)
        }
        if let b = d["$bindItem"], case let .string(f) = b {
            if let item = ctx.repeatItem {
                let v: JSONValue = f.isEmpty ? item : (item.objectValue?[f] ?? .null)
                return ResolveResult(value: v, bindingPath: "$item:\(f)")
            }
            return ResolveResult(value: .null, bindingPath: nil)
        }
        if let s = d["$state"], case let .string(p) = s, d.count == 1 {
            return ResolveResult(value: getByPath(ctx.state, p) ?? .null, bindingPath: nil)
        }
        if d["$item"] != nil && d["$state"] == nil && d["$computed"] == nil && d["$template"] == nil && d["$cond"] == nil {
            // $item read (may include comparison keys in visibility only; here plain read)
            if case let .string(f) = d["$item"] ?? .null, let item = ctx.repeatItem {
                let v: JSONValue = f.isEmpty ? item : (item.objectValue?[f] ?? .null)
                return ResolveResult(value: v, bindingPath: nil)
            }
            return ResolveResult(value: .null, bindingPath: nil)
        }
        if d["$index"] != nil {
            if let idx = ctx.repeatIndex { return ResolveResult(value: .int(idx), bindingPath: nil) }
            return ResolveResult(value: .null, bindingPath: nil)
        }
        if let c = d["$cond"] {
            let thenV = d["$then"] ?? .null
            let elseV = d["$else"] ?? .null
            // $cond uses visibility expression format; wrap minimal eval
            let condResult = evalCondValue(c, ctx: ctx)
            let chosen = condResult ? thenV : elseV
            // chosen may itself be expression
            return resolvePropValue(chosen, ctx: ctx)
        }
        if let t = d["$template"], case let .string(s) = t {
            return ResolveResult(value: .string(interpolate(s, ctx: ctx)), bindingPath: nil)
        }
        if let fn = d["$computed"], case let .string(name) = fn {
            let argsRaw = d["args"]?.objectValue ?? [:]
            var args: [String: JSONValue] = [:]
            for (k, v) in argsRaw { args[k] = resolvePropValue(v, ctx: ctx).value }
            if let f = ctx.functions[name] { return ResolveResult(value: f(args), bindingPath: nil) }
            return ResolveResult(value: .null, bindingPath: nil)
        }
    }
    return ResolveResult(value: raw, bindingPath: nil)
}

private func evalCondValue(_ v: JSONValue, ctx: EvalContext) -> Bool {
    // Accept VisibilityCondition JSON or plain $state truthiness object
    if let data = try? JSONEncoder().encode(v),
       let cond = try? JSONDecoder().decode(VisibilityCondition.self, from: data) {
        return evaluateVisibility(cond, ctx: ctx)
    }
    // Fallback: resolve then truthy
    let r = resolvePropValue(v, ctx: ctx).value
    switch r {
    case .bool(let b): return b
    case .null: return false
    case .string(let s): return !s.isEmpty
    case .int(let i): return i != 0
    case .double(let d): return d != 0
    case .array(let a): return !a.isEmpty
    case .object(let o): return !o.isEmpty
    }
}

private func interpolate(_ template: String, ctx: EvalContext) -> String {
    // ${/path} syntax; missing -> ""
    var result = ""
    var i = template.startIndex
    while i < template.endIndex {
        if template[i] == "$", template.index(after: i) < template.endIndex, template[template.index(after: i)] == "{",
           let close = template[template.index(after: template.index(after: i))...].firstIndex(of: "}") {
            let start = template.index(i, offsetBy: 2)
            let path = String(template[start..<close])
            if let v = getByPath(ctx.state, path) {
                result += stringify(v)
            }
            i = template.index(after: close)
        } else {
            result.append(template[i])
            i = template.index(after: i)
        }
    }
    return result
}

private func stringify(_ v: JSONValue) -> String {
    switch v {
    case .null: return ""
    case .bool(let b): return b ? "true" : "false"
    case .int(let i): return String(i)
    case .double(let d): return String(d)
    case .string(let s): return s
    case .array, .object:
        if let data = try? JSONEncoder().encode(v), let s = String(data: data, encoding: .utf8) { return s }
        return ""
    }
}
