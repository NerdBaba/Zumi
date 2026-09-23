import SwiftUI
import AppKit
import JRCore

// MARK: - Registry

public struct ComponentContext {
    public var props: [String: JSONValue]
    public var resolved: [String: ResolveResult]
    public var children: AnyView?
    public var slots: [String: AnyView]
    public var emit: (String) -> Void
    public var bindings: [String: String]
    public var loading: Bool
    public var write: (String, JSONValue) -> Void
}

public typealias JRComponent = @MainActor (ComponentContext) -> AnyView

public struct Registry {
    public var components: [String: JRComponent]
    public init(_ components: [String: JRComponent] = [:]) { self.components = components }
}

public func defineRegistry(_ catalog: Catalog, _ builders: [String: JRComponent]) -> Registry {
    Registry(builders)
}

// MARK: - Action execution

@MainActor
public final class ActionDispatcher: ObservableObject {
    public typealias Handler = ([String: JSONValue], @escaping (String, JSONValue) -> Void, [String: JSONValue]) async throws -> Void

    public var handlers: [String: Handler]
    public var timeline: [(name: String, params: [String: JSONValue], error: String?)] = []
    public weak var store: StateStore?

    public init(handlers: [String: Handler] = [:]) {
        self.handlers = handlers
    }

    public func execute(_ binding: ActionBinding, ctx: EvalContext) async {
        var params: [String: JSONValue] = [:]
        for (key, value) in binding.params ?? [:] {
            params[key] = resolvePropValue(value, ctx: ctx).value
        }

        if let confirmation = binding.confirm, !confirm(confirmation) {
            timeline.insert((binding.action, params, "Cancelled by user"), at: 0)
            return
        }

        switch binding.action {
        case "setState":
            if case let .string(path) = params["statePath"], let value = params["value"] {
                store?.set(path, value)
            }
            apply(binding.onSuccess, ctx: ctx)
            timeline.insert((binding.action, params, nil), at: 0)
            return
        case "pushState":
            if case let .string(path) = params["statePath"],
               let value = params["value"],
               var array = store?.get(path)?.arrayValue {
                array.append(value)
                store?.set(path, .array(array))
            }
            apply(binding.onSuccess, ctx: ctx)
            timeline.insert((binding.action, params, nil), at: 0)
            return
        case "removeState":
            if case let .string(path) = params["statePath"] { store?.remove(path) }
            apply(binding.onSuccess, ctx: ctx)
            timeline.insert((binding.action, params, nil), at: 0)
            return
        case "validateForm":
            NotificationCenter.default.post(
                name: .jrValidateForm,
                object: params["statePath"]?.stringValue ?? "/formValidation"
            )
            apply(binding.onSuccess, ctx: ctx)
            timeline.insert((binding.action, params, nil), at: 0)
            return
        default:
            break
        }

        guard let handler = handlers[binding.action], let store else {
            apply(binding.onError, ctx: ctx)
            timeline.insert((binding.action, params, "Unknown action"), at: 0)
            return
        }

        let setter: (String, JSONValue) -> Void = { path, value in
            if path.hasPrefix("/") {
                store.set(path, value)
            } else {
                store.update([path: value])
            }
        }
        do {
            try await handler(params, setter, store.state)
            apply(binding.onSuccess, ctx: ctx)
            timeline.insert((binding.action, params, nil), at: 0)
        } catch {
            apply(binding.onError, ctx: ctx)
            timeline.insert((binding.action, params, error.localizedDescription), at: 0)
        }
    }

    private func apply(_ result: ActionSet?, ctx: EvalContext) {
        guard let assignments = result?.set else { return }
        for (path, rawValue) in assignments {
            let value = resolvePropValue(rawValue, ctx: ctx).value
            if path.hasPrefix("/") {
                store?.set(path, value)
            } else {
                store?.update([path: value])
            }
        }
    }

    private func confirm(_ confirmation: ActionConfirm) -> Bool {
        let alert = NSAlert()
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.message
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

public extension Notification.Name {
    static let jrValidateForm = Notification.Name("jrValidateForm")
}

// MARK: - Standard registry (Core + layout -> SwiftUI)

@MainActor
public func zumiStandardRegistry(store: StateStore, dispatcher: ActionDispatcher, functions: [String: @Sendable ([String: JSONValue]) -> JSONValue] = standardFunctions) -> Registry {
    func R(_ v: JSONValue, ctx: EvalContext) -> JSONValue { resolvePropValue(v, ctx: ctx).value }
    func S(_ props: [String: JSONValue], _ key: String, ctx: EvalContext, fallback: String = "") -> String {
        if let raw = props[key] { return R(raw, ctx: ctx).stringValue ?? fallback }
        return fallback
    }

    var m: [String: JRComponent] = [:]
    m["VStack"] = { c in AnyView(VStack(spacing: 8) { c.children }) }
    m["HStack"] = { c in AnyView(HStack(spacing: 8) { c.children }) }
    m["ZStack"] = { c in AnyView(ZStack { c.children }) }
    m["Grid"] = { c in
        let cols = Int(c.props["columns"]?.intValue ?? 2)
        return AnyView(LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: max(1, cols)), spacing: 12) { c.children })
    }
    m["Card"] = { c in
        let title = c.resolved["title"]?.value.stringValue ?? ""
        return AnyView(GroupBox(title.isEmpty ? "" : title) { VStack(alignment: .leading, spacing: 8) { c.children } })
    }
    m["Section"] = { c in
        let h = c.resolved["header"]?.value.stringValue ?? ""
        return AnyView(Section(header: Text(h)) { c.children })
    }
    m["Form"] = { c in AnyView(Form { c.children }) }
    m["Tabs"] = { c in AnyView(TabView { c.children }) }
    m["List"] = { c in AnyView(List { c.children }) }
    m["Table"] = { c in AnyView(VStack(alignment: .leading, spacing: 4) { c.children }) }
    m["ScrollView"] = { c in AnyView(ScrollView { c.children }) }
    m["Text"] = { c in AnyView(Text(c.resolved["content"]?.value.stringValue ?? c.resolved["text"]?.value.stringValue ?? "")) }
    m["Heading"] = { c in AnyView(Text(c.resolved["text"]?.value.stringValue ?? "").font(.headline)) }
    m["Image"] = { c in
        let src = c.resolved["src"]?.value.stringValue ?? ""
        return AnyView(AsyncImage(url: URL(string: src)) { img in img.resizable().scaledToFit() } placeholder: { Color.gray.opacity(0.2).frame(height: 80) })
    }
    m["Divider"] = { _ in AnyView(Divider()) }
    m["Spacer"] = { _ in AnyView(Spacer()) }
    m["Badge"] = { c in AnyView(Text(c.resolved["label"]?.value.stringValue ?? "").padding(4).background(Color.accentColor.opacity(0.15)).cornerRadius(6)) }
    m["Progress"] = { c in
        let v = c.resolved["value"]?.value.doubleValue ?? 0
        let t = c.resolved["total"]?.value.doubleValue ?? 100
        return AnyView(ProgressView(value: v, total: t == 0 ? 100 : t))
    }
    m["Button"] = { c in
        let label = c.resolved["label"]?.value.stringValue ?? "Button"
        return AnyView(Button(label) { c.emit("press") })
    }
    m["TextField"] = { c in
        let ph = c.resolved["placeholder"]?.value.stringValue ?? ""
        let path = c.bindings["value"]
        let cur = c.resolved["value"]?.value ?? .string("")
        let label = c.resolved["label"]?.value.stringValue ?? ""
        let checks = c.props["checks"].map(checksFromProp) ?? []
        let validateOn = c.resolved["validateOn"]?.value.stringValue ?? "change"
        let enabled = c.resolved["enabled"]?.value.boolValue ?? true
        return AnyView(JRTextField(
            label: label,
            placeholder: ph,
            path: path,
            current: cur,
            checks: checks,
            validateOn: validateOn,
            enabled: enabled,
            store: store,
            write: c.write,
            emit: c.emit
        ))
    }
    m["SecureField"] = { c in
        let ph = c.resolved["placeholder"]?.value.stringValue ?? ""
        let path = c.bindings["value"]
        let cur = c.resolved["value"]?.value ?? .string("")
        let enabled = c.resolved["enabled"]?.value.boolValue ?? true
        let binding = Binding<String>(
            get: { cur.stringValue ?? "" },
            set: {
                if let path { c.write(path, .string($0)) }
                c.emit("change")
            }
        )
        return AnyView(SecureField(ph, text: binding).disabled(!enabled).onSubmit { c.emit("submit") })
    }
    m["TextArea"] = { c in
        let path = c.bindings["value"]
        let cur = c.resolved["value"]?.value ?? .string("")
        let enabled = c.resolved["enabled"]?.value.boolValue ?? true
        let binding = Binding<String>(
            get: { cur.stringValue ?? "" },
            set: {
                if let path { c.write(path, .string($0)) }
                c.emit("change")
            }
        )
        return AnyView(TextEditor(text: binding).frame(minHeight: 80).disabled(!enabled))
    }
    m["Toggle"] = { c in
        let label = c.resolved["label"]?.value.stringValue ?? ""
        let path = c.bindings["checked"]
        let cur = c.resolved["checked"]?.value.boolValue ?? false
        let enabled = c.resolved["enabled"]?.value.boolValue ?? true
        let binding = Binding(get: { cur }, set: {
            if let path { c.write(path, .bool($0)) }
            c.emit("change")
        })
        return AnyView(Toggle(label, isOn: binding).disabled(!enabled))
    }
    m["Checkbox"] = { c in
        let label = c.resolved["label"]?.value.stringValue ?? ""
        let path = c.bindings["checked"]
        let cur = c.resolved["checked"]?.value.boolValue ?? false
        let enabled = c.resolved["enabled"]?.value.boolValue ?? true
        let binding = Binding(get: { cur }, set: {
            if let path { c.write(path, .bool($0)) }
            c.emit("change")
        })
        return AnyView(Toggle(label, isOn: binding).toggleStyle(.checkbox).disabled(!enabled))
    }
    m["Slider"] = { c in
        let path = c.bindings["value"]
        let cur = c.resolved["value"]?.value.doubleValue ?? 0
        let lo = c.resolved["min"]?.value.doubleValue ?? 0
        let hi = c.resolved["max"]?.value.doubleValue ?? 100
        let enabled = c.resolved["enabled"]?.value.boolValue ?? true
        let binding = Binding(get: { cur }, set: {
            if let path { c.write(path, .double($0)) }
            c.emit("change")
        })
        return AnyView(Slider(value: binding, in: lo...hi).disabled(!enabled))
    }
    m["Picker"] = { c in
        let label = c.resolved["label"]?.value.stringValue ?? ""
        let path = c.bindings["value"]
        let cur = c.resolved["value"]?.value.stringValue ?? ""
        let opts = c.resolved["options"]?.value.arrayValue?.compactMap { $0.stringValue } ?? []
        let enabled = c.resolved["enabled"]?.value.boolValue ?? true
        let binding = Binding(get: { cur }, set: {
            if let path { c.write(path, .string($0)) }
            c.emit("change")
        })
        return AnyView(Picker(label, selection: binding) {
            ForEach(opts, id: \.self) { Text($0).tag($0) }
        }.disabled(!enabled))
    }
    m["DatePicker"] = { c in
        let label = c.resolved["label"]?.value.stringValue ?? ""
        let path = c.bindings["value"]
        let raw = c.resolved["value"]?.value.stringValue ?? ""
        let enabled = c.resolved["enabled"]?.value.boolValue ?? true
        let date = ISO8601DateFormatter().date(from: raw) ?? Date()
        let binding = Binding(get: { date }, set: {
            if let path {
                c.write(path, .string(ISO8601DateFormatter().string(from: $0)))
            }
            c.emit("change")
        })
        return AnyView(DatePicker(label, selection: binding, displayedComponents: .date).disabled(!enabled))
    }
    return Registry(m)
}

private struct JRTextField: View {
    var label: String
    var placeholder: String
    var path: String?
    var current: JSONValue
    var checks: [ValidationCheck]
    var validateOn: String
    var enabled: Bool
    @ObservedObject var store: StateStore
    var write: (String, JSONValue) -> Void
    var emit: (String) -> Void
    @State private var errors: [String] = []
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !label.isEmpty { Text(label).font(.caption) }
            TextField(placeholder, text: Binding(
                get: { current.stringValue ?? "" },
                set: {
                    if let path { write(path, .string($0)) }
                    if validateOn == "change" { runValidate() }
                    emit("change")
                }
            ))
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .disabled(!enabled)
                .onChange(of: isFocused) { wasFocused, focused in
                    if wasFocused && !focused {
                        if validateOn == "blur" { runValidate() }
                        emit("blur")
                    }
                }
                .onSubmit {
                    if validateOn == "submit" { runValidate() }
                    emit("submit")
                }
                .onChange(of: store.state) { _, _ in
                    if validateOn == "change" { runValidate() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .jrValidateForm)) { _ in runValidate() }
            ForEach(errors, id: \.self) { Text($0).font(.caption).foregroundColor(.red) }
        }
    }

    func runValidate() {
        let value: JSONValue
        if let path, !path.hasPrefix("$item:"), let stateValue = store.get(path) {
            value = stateValue
        } else {
            value = current
        }
        errors = validateField(value: value, checks: checks, state: store.state)
    }
}
