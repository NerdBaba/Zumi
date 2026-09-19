import Foundation
import Combine
import SwiftUI
import JRCore

@MainActor
public final class StateStore: ObservableObject {
    @Published public private(set) var state: [String: JSONValue]
    public var onStateChange: (([(path: String, value: JSONValue)]) -> Void)?

    public init(initialState: [String: JSONValue] = [:], onStateChange: ((([(path: String, value: JSONValue)])) -> Void)? = nil) {
        self.state = initialState
        self.onStateChange = onStateChange
    }

    public func get(_ path: String) -> JSONValue? { getByPath(state, path) }

    public func set(_ path: String, _ value: JSONValue) {
        var root = JSONValue.object(state)
        if path.hasPrefix("$item:") {
            // $bindItem writes are handled by parent repeat scope via updateItem; ignore direct
            return
        }
        guard setByPath(&root, path, value) else {
            // Create intermediate objects for new paths
            let tokens = splitPointer(path) ?? []
            if !tokens.isEmpty {
                var cur: [String: JSONValue] = state
                // naive deep create
                func insert(_ dict: inout [String: JSONValue], _ toks: [String]) {
                    if toks.count == 1 { dict[toks[0]] = value; return }
                    var child = dict[toks[0]]?.objectValue ?? [:]
                    insert(&child, Array(toks.dropFirst()))
                    dict[toks[0]] = .object(child)
                }
                insert(&cur, tokens)
                state = cur
                onStateChange?([(path, value)])
                return
            }
            return
        }
        if case let .object(o) = root { state = o }
        onStateChange?([(path, value)])
    }

    public func update(_ updates: [String: JSONValue]) {
        for (k, v) in updates {
            // keys may be paths or plain keys
            if k.hasPrefix("/") { set(k, v) } else { state[k] = v }
        }
        onStateChange?(updates.map { ($0.key, $0.value) })
    }

    public func remove(_ path: String) {
        var root = JSONValue.object(state)
        if removeByPath(&root, path), case let .object(o) = root {
            state = o
            onStateChange?([(path, .null)])
        }
    }

    public func evalContext(repeatItem: JSONValue? = nil, repeatIndex: Int? = nil, functions: [String: @Sendable ([String: JSONValue]) -> JSONValue] = standardFunctions) -> EvalContext {
        EvalContext(state: state, repeatItem: repeatItem, repeatIndex: repeatIndex, functions: functions)
    }
}

@MainActor
public func bindingFor(store: StateStore, path: String?, current: JSONValue, asString: Bool = true) -> Binding<String> {
    Binding(
        get: {
            if case let .string(s) = current { return s }
            if case let .int(i) = current { return String(i) }
            if case let .double(d) = current { return String(d) }
            if case let .bool(b) = current { return b ? "true" : "false" }
            return ""
        },
        set: { new in
            guard let p = path, !p.hasPrefix("$item:") else { return }
            if asString { store.set(p, .string(new)) }
        }
    )
}

@MainActor
public func setPath(_ store: StateStore, _ path: String?, _ value: JSONValue) {
    guard let p = path, !p.hasPrefix("$item:") else { return }
    store.set(p, value)
}
