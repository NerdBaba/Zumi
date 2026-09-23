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
        guard !path.hasPrefix("$item:"), get(path) != value else { return }
        guard write(path, value) else { return }
        onStateChange?([(path, value)])
    }

    public func update(_ updates: [String: JSONValue]) {
        var changes: [(path: String, value: JSONValue)] = []
        for (path, value) in updates {
            let previous = path.hasPrefix("/") ? get(path) : state[path]
            guard previous != value else { continue }
            let succeeded: Bool
            if path.hasPrefix("/") {
                succeeded = write(path, value)
            } else {
                state[path] = value
                succeeded = true
            }
            if succeeded { changes.append((path, value)) }
        }
        if !changes.isEmpty { onStateChange?(changes) }
    }

    private func write(_ path: String, _ value: JSONValue) -> Bool {
        var root = JSONValue.object(state)
        if setByPath(&root, path, value), case let .object(object) = root {
            state = object
            return true
        }

        // Create missing object parents for newly introduced state paths.
        guard let tokens = splitPointer(path), !tokens.isEmpty else { return false }
        var updated = state
        func insert(_ object: inout [String: JSONValue], _ remaining: ArraySlice<String>) {
            guard let first = remaining.first else { return }
            if remaining.count == 1 {
                object[first] = value
                return
            }
            var child = object[first]?.objectValue ?? [:]
            insert(&child, remaining.dropFirst())
            object[first] = .object(child)
        }
        insert(&updated, tokens[...])
        state = updated
        return true
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
