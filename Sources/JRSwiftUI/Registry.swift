import SwiftUI
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
    public var handlers: [String: ([String: JSONValue], @escaping (String, JSONValue) -> Void, [String: JSONValue]) async -> Void]
    public var timeline: [(name: String, params: [String: JSONValue], error: String?)] = []
    public weak var store: StateStore?

    public init(handlers: [String: ([String: JSONValue], @escaping (String, JSONValue) -> Void, [String: JSONValue]) async -> Void] = [:]) {
        self.handlers = handlers
    }

    public func execute(_ binding: ActionBinding, ctx: EvalContext) async {
        var params: [String: JSONValue] = [:]
        for (k, v) in (binding.params ?? [:]) { params[k] = resolvePropValue(v, ctx: ctx).value }
        // Built-ins
        switch binding.action {
        case "setState":
            if case let .string(p) = params["statePath"] ?? .null, let v = params["value"] {
                store?.set(p, v)
            }
            timeline.insert((binding.action, params, nil), at: 0); return
        case "pushState":
            if case let .string(p) = params["statePath"] ?? .null, let v = params["value"],
               var arr = store?.get(p)?.arrayValue {
                arr.append(v); store?.set(p, .array(arr))
            }
            timeline.insert((binding.action, params, nil), at: 0); return
        case "removeState":
            if case let .string(p) = params["statePath"] ?? .null {
                store?.remove(p)
            }
            timeline.insert((binding.action, params, nil), at: 0); return
        case "validateForm":
            timeline.insert((binding.action, params, nil), at: 0)
            NotificationCenter.default.post(name: .jrValidateForm, object: params["statePath"]?.stringValue ?? "/formValidation")
            return
        default: break
        }
        if let h = handlers[binding.action], let store {
            let setter: (String, JSONValue) -> Void = { p, v in store.set(p, v) }
            await h(params, setter, store.state)
            timeline.insert((binding.action, params, nil), at: 0)
            if let onSuccess = binding.onSuccess?.set { for (k, v) in onSuccess { store.set(k, v) } }
        } else {
            timeline.insert((binding.action, params, "Unknown action"), at: 0)
        }
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
        let write = c.write
        return AnyView(JRTextField(label: label, placeholder: ph, path: path, current: cur, checks: checks, store: store, write: write))
    }
    m["SecureField"] = { c in
        let ph = c.resolved["placeholder"]?.value.stringValue ?? ""
        let path = c.bindings["value"]
        let cur = c.resolved["value"]?.value ?? .string("")
        let write = c.write
        let binding = Binding<String>(
            get: { cur.stringValue ?? "" },
            set: { if let p = path { write(p, .string($0)) } }
        )
        return AnyView(SecureField(ph, text: binding))
    }
    m["TextArea"] = { c in
        let path = c.bindings["value"]
        let cur = c.resolved["value"]?.value ?? .string("")
        let write = c.write
        let binding = Binding<String>(
            get: { cur.stringValue ?? "" },
            set: { if let p = path { write(p, .string($0)) } }
        )
        return AnyView(TextEditor(text: binding).frame(minHeight: 80))
    }
    m["Toggle"] = { c in
        let label = c.resolved["label"]?.value.stringValue ?? ""
        let path = c.bindings["checked"]
        let cur = c.resolved["checked"]?.value.boolValue ?? false
        let write = c.write
        return AnyView(Toggle(label, isOn: Binding(get: { cur }, set: { if let p = path { write(p, .bool($0)) } })))
    }
    m["Checkbox"] = m["Toggle"]!
    m["Slider"] = { c in
        let path = c.bindings["value"]
        let cur = c.resolved["value"]?.value.doubleValue ?? 0
        let lo = c.resolved["min"]?.value.doubleValue ?? 0
        let hi = c.resolved["max"]?.value.doubleValue ?? 100
        let write = c.write
        return AnyView(Slider(value: Binding(get: { cur }, set: { if let p = path { write(p, .double($0)) } }), in: lo...hi))
    }
    m["Picker"] = { c in
        let label = c.resolved["label"]?.value.stringValue ?? ""
        let path = c.bindings["value"]
        let cur = c.resolved["value"]?.value.stringValue ?? ""
        let opts = c.resolved["options"]?.value.arrayValue?.compactMap { $0.stringValue } ?? []
        let write = c.write
        return AnyView(Picker(label, selection: Binding(get: { cur }, set: { if let p = path { write(p, .string($0)) } })) {
            ForEach(opts, id: \.self) { Text($0).tag($0) }
        })
    }
    m["DatePicker"] = { c in
        let label = c.resolved["label"]?.value.stringValue ?? ""
        return AnyView(DatePicker(label, selection: .constant(Date())))
    }
    return Registry(m)
}

private struct JRTextField: View {
    var label: String
    var placeholder: String
    var path: String?
    var current: JSONValue
    var checks: [ValidationCheck]
    @ObservedObject var store: StateStore
    var write: (String, JSONValue) -> Void
    @State private var errors: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !label.isEmpty { Text(label).font(.caption) }
            TextField(placeholder, text: Binding(
                get: { current.stringValue ?? "" },
                set: { if let p = path { write(p, .string($0)) } }
            ))
                .textFieldStyle(.roundedBorder)
                .onChange(of: store.state) { _, _ in runValidate() }
                .onAppear { runValidate() }
                .onReceive(NotificationCenter.default.publisher(for: .jrValidateForm)) { _ in runValidate() }
            ForEach(errors, id: \.self) { Text($0).font(.caption).foregroundColor(.red) }
        }
    }
    func runValidate() {
        let v: JSONValue
        if let p = path, !p.hasPrefix("$item:"), let sv = store.get(p) { v = sv } else { v = current }
        errors = validateField(value: v, checks: checks, state: store.state)
    }
}
