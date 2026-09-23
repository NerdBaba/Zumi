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
    Registry(builders.filter { catalog.components[$0.key] != nil })
}

// MARK: - Action execution

@MainActor
public final class ActionDispatcher: ObservableObject {
    public typealias Handler = ([String: JSONValue], @escaping (String, JSONValue) -> Void, [String: JSONValue]) async throws -> Void

    public var handlers: [String: Handler]
    @Published public private(set) var timeline: [(name: String, params: [String: JSONValue], error: String?)] = []
    public weak var store: StateStore?
    public var formValidator: (([String: JSONValue]) -> Bool)?

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
            let valid = formValidator?(store?.state ?? ctx.state) ?? false
            let path = params["statePath"]?.stringValue ?? "/formValidation"
            store?.set(path, .object(["valid": .bool(valid)]))
            NotificationCenter.default.post(name: .jrValidateForm, object: valid)
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

    func number(_ context: ComponentContext, _ key: String, default fallback: Double) -> Double {
        context.resolved[key]?.value.doubleValue ?? fallback
    }
    func verticalAlignment(_ raw: String?) -> VerticalAlignment {
        switch raw {
        case "top": return .top
        case "bottom": return .bottom
        case "firstTextBaseline": return .firstTextBaseline
        case "lastTextBaseline": return .lastTextBaseline
        default: return .center
        }
    }
    func horizontalAlignment(_ raw: String?) -> HorizontalAlignment {
        switch raw {
        case "leading": return .leading
        case "trailing": return .trailing
        default: return .center
        }
    }
    func alignment(_ raw: String?) -> Alignment {
        switch raw {
        case "top": return .top
        case "bottom": return .bottom
        case "leading": return .leading
        case "trailing": return .trailing
        case "topLeading": return .topLeading
        case "topTrailing": return .topTrailing
        case "bottomLeading": return .bottomLeading
        case "bottomTrailing": return .bottomTrailing
        default: return .center
        }
    }

    var m: [String: JRComponent] = [:]
    m["VStack"] = { c in
        let spacing = max(0, number(c, "spacing", default: 8))
        let padding = max(0, number(c, "padding", default: 0))
        let stack = VStack(alignment: horizontalAlignment(c.resolved["alignment"]?.value.stringValue), spacing: spacing) { c.children }
        return AnyView(stack.padding(padding))
    }
    m["HStack"] = { c in
        let spacing = max(0, number(c, "spacing", default: 8))
        let padding = max(0, number(c, "padding", default: 0))
        let stack = HStack(alignment: verticalAlignment(c.resolved["alignment"]?.value.stringValue), spacing: spacing) { c.children }
        return AnyView(stack.padding(padding))
    }
    m["ZStack"] = { c in
        let stack = ZStack(alignment: alignment(c.resolved["alignment"]?.value.stringValue)) { c.children }
        return AnyView(stack.padding(max(0, number(c, "padding", default: 0))))
    }
    m["Grid"] = { c in
        let columns = max(1, Int(number(c, "columns", default: 2)))
        let spacing = max(0, number(c, "spacing", default: 12))
        return AnyView(LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: columns), spacing: spacing) { c.children })
    }
    m["Card"] = { c in
        let title = c.resolved["title"]?.value.stringValue ?? ""
        let subtitle = c.resolved["subtitle"]?.value.stringValue
        return AnyView(GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if let header = c.slots["header"] { header }
                c.children
                if let footer = c.slots["footer"] { footer }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle, !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundColor(.secondary) }
            }
        })
    }
    m["Section"] = { c in
        let header = c.resolved["header"]?.value.stringValue ?? ""
        return AnyView(Section {
            c.children
            if let footer = c.slots["footer"] { footer }
        } header: {
            if let customHeader = c.slots["header"] { customHeader }
            else { Text(header) }
        })
    }
    m["Form"] = { c in AnyView(Form { c.children }) }
    m["Tabs"] = { c in AnyView(TabView { c.children }) }
    m["List"] = { c in AnyView(List { c.children }) }
    m["Table"] = { c in AnyView(VStack(alignment: .leading, spacing: 4) { c.children }) }
    m["ScrollView"] = { c in
        let axes: Axis.Set
        switch c.resolved["axes"]?.value.stringValue {
        case "horizontal": axes = .horizontal
        case "both": axes = [.horizontal, .vertical]
        default: axes = .vertical
        }
        return AnyView(ScrollView(axes) { c.children })
    }
    m["Text"] = { c in
        let text = c.resolved["content"]?.value.stringValue ?? c.resolved["text"]?.value.stringValue ?? ""
        let variant = c.resolved["variant"]?.value.stringValue ?? "body"
        let view = Text(text)
        switch variant {
        case "title": return AnyView(view.font(.title))
        case "headline": return AnyView(view.font(.headline))
        case "caption": return AnyView(view.font(.caption))
        case "secondary": return AnyView(view.foregroundColor(.secondary))
        case "code": return AnyView(view.font(.system(.body, design: .monospaced)))
        default: return AnyView(view)
        }
    }
    m["Heading"] = { c in
        let text = c.resolved["text"]?.value.stringValue ?? ""
        let level = c.resolved["level"]?.value.intValue ?? 1
        let view = Text(text)
        switch level {
        case ...1: return AnyView(view.font(.largeTitle).bold())
        case 2: return AnyView(view.font(.title).bold())
        case 3: return AnyView(view.font(.title2).bold())
        case 4: return AnyView(view.font(.title3).bold())
        default: return AnyView(view.font(.headline))
        }
    }
    m["Image"] = { c in
        let source = c.resolved["src"]?.value.stringValue ?? ""
        let alt = c.resolved["alt"]?.value.stringValue ?? ""
        let url = URL(string: source).flatMap { candidate in
            ["https", "http"].contains(candidate.scheme?.lowercased() ?? "") ? candidate : nil
        }
        return AnyView(AsyncImage(url: url) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Color.gray.opacity(0.2).frame(height: 80)
        }.accessibilityLabel(alt))
    }
    m["Divider"] = { _ in AnyView(Divider()) }
    m["Spacer"] = { _ in AnyView(Spacer()) }
    m["Badge"] = { c in AnyView(Text(c.resolved["label"]?.value.stringValue ?? "").padding(4).background(Color.accentColor.opacity(0.15)).cornerRadius(6)) }
    m["Progress"] = { c in
        let value = c.resolved["value"]?.value.doubleValue ?? 0
        let total = max(Double.leastNonzeroMagnitude, c.resolved["total"]?.value.doubleValue ?? 100)
        return AnyView(ProgressView(value: min(total, max(0, value)), total: total))
    }
    m["Button"] = { c in
        let label = c.resolved["label"]?.value.stringValue ?? "Button"
        let enabled = c.resolved["enabled"]?.value.boolValue ?? true
        return AnyView(Button(label) { c.emit("press") }.disabled(!enabled))
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
