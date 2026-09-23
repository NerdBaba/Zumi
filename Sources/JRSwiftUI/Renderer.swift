import SwiftUI
import JRCore

// MARK: - Renderer (flat spec -> SwiftUI, progressive + safe)

public struct Renderer: View {
    public var spec: Spec?
    public var registry: Registry
    public var catalog: Catalog?
    @ObservedObject public var store: StateStore
    @ObservedObject public var dispatcher: ActionDispatcher
    public var functions: [String: @Sendable ([String: JSONValue]) -> JSONValue]
    public var loading: Bool
    public var fallback: ((String) -> AnyView)?

    public init(spec: Spec?, registry: Registry, store: StateStore, dispatcher: ActionDispatcher, functions: [String: @Sendable ([String: JSONValue]) -> JSONValue] = standardFunctions, loading: Bool = false, fallback: ((String) -> AnyView)? = nil, catalog: Catalog? = nil) {
        self.spec = spec
        self.registry = registry
        self.catalog = catalog
        self.store = store
        self.dispatcher = dispatcher
        self.functions = functions
        self.loading = loading
        self.fallback = fallback
    }

    public var body: some View {
        Group {
            if let spec {
                let issues = catalog?.validate(spec: spec) ?? validateSpec(spec).issues
                if !issues.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("This spec cannot be rendered", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundColor(.orange)
                        ForEach(Array(issues.prefix(5).enumerated()), id: \.offset) { entry in
                            Text("\(entry.element.path): \(entry.element.message)")
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                } else if let root = spec.root, spec.elements[root] != nil {
                    ElementView(key: root, spec: spec, registry: registry, store: store, dispatcher: dispatcher, functions: functions, fallback: fallback, item: nil, index: nil, arrayPath: nil, arrayIndex: nil)
                } else if loading {
                    VStack(spacing: 12) { ProgressView(); Text("Generating…").foregroundColor(.secondary) }.padding()
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "rectangle.dashed").font(.largeTitle).foregroundColor(.secondary)
                        Text("No UI yet — describe what you want.").foregroundColor(.secondary)
                    }.padding()
                }
            } else if loading {
                VStack(spacing: 12) { ProgressView(); Text("Generating…").foregroundColor(.secondary) }.padding()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.dashed").font(.largeTitle).foregroundColor(.secondary)
                    Text("No UI yet — describe what you want.").foregroundColor(.secondary)
                }.padding()
            }
        }
        .overlay { if loading { ProgressView().padding() } }
    }
}

@MainActor
func makeWrite(store: StateStore, arrayPath: String?, arrayIndex: Int?) -> (String, JSONValue) -> Void {
    { binding, value in
        if binding.hasPrefix("/") {
            store.set(binding, value)
        } else if binding.hasPrefix("$item:"), let ap = arrayPath, let ai = arrayIndex {
            let field = String(binding.dropFirst(6))
            // Read array, update element field (or whole element if field empty)
            guard var arr = store.get(ap)?.arrayValue, ai < arr.count else { return }
            if field.isEmpty {
                arr[ai] = value
            } else {
                var obj = arr[ai].objectValue ?? [:]
                obj[field] = value
                arr[ai] = .object(obj)
            }
            store.set(ap, .array(arr))
        }
    }
}

struct ElementView: View {
    var key: String
    var spec: Spec
    var registry: Registry
    @ObservedObject var store: StateStore
    @ObservedObject var dispatcher: ActionDispatcher
    var functions: [String: @Sendable ([String: JSONValue]) -> JSONValue]
    var fallback: ((String) -> AnyView)?
    var item: JSONValue?
    var index: Int?
    var arrayPath: String?
    var arrayIndex: Int?

    var body: some View {
        guard let el = spec.elements[key] else { return AnyView(EmptyView()) }
        if let rep = el.repeatConfig {
            return AnyView(RepeatView(key: key, element: el, rep: rep, spec: spec, registry: registry, store: store, dispatcher: dispatcher, functions: functions, fallback: fallback, outerItem: item, outerIndex: index, outerArrayPath: arrayPath, outerArrayIndex: arrayIndex))
        }
        let ctx = store.evalContext(repeatItem: item, repeatIndex: index, functions: functions)
        if !evaluateVisibility(el.visible, ctx: ctx) { return AnyView(EmptyView()) }
        var resolved: [String: ResolveResult] = [:]
        var bindings: [String: String] = [:]
        for (k, v) in el.props {
            let r = resolvePropValue(v, ctx: ctx)
            resolved[k] = r
            if let b = r.bindingPath { bindings[k] = b }
        }
        let write = makeWrite(store: store, arrayPath: arrayPath, arrayIndex: arrayIndex)
        let childViews: AnyView = {
            let kids = (el.children ?? []).map { ck in
                AnyView(ElementView(key: ck, spec: spec, registry: registry, store: store, dispatcher: dispatcher, functions: functions, fallback: fallback, item: item, index: index, arrayPath: arrayPath, arrayIndex: arrayIndex))
            }
            return AnyView(ForEach(0..<kids.count, id: \.self) { kids[$0] })
        }()
        var slotViews: [String: AnyView] = [:]
        for (name, arr) in (el.slots ?? [:]) where name != "default" {
            let views = arr.map { ck in AnyView(ElementView(key: ck, spec: spec, registry: registry, store: store, dispatcher: dispatcher, functions: functions, fallback: fallback, item: item, index: index, arrayPath: arrayPath, arrayIndex: arrayIndex)) }
            slotViews[name] = AnyView(ForEach(0..<views.count, id: \.self) { views[$0] })
        }
        guard let comp = registry.components[el.type] else {
            if let fb = fallback { return fb(el.type) }
            return AnyView(Text("Unknown: \(el.type)").foregroundColor(.red).font(.caption))
        }
        let emit: (String) -> Void = { event in
            guard let bindings = el.on?[event] else { return }
            Task { @MainActor in
                for binding in bindings.all {
                    await dispatcher.execute(binding, ctx: ctx)
                }
            }
        }
        let ctxObj = ComponentContext(props: el.props, resolved: resolved, children: childViews, slots: slotViews, emit: emit, bindings: bindings, loading: false, write: write)
        return comp(ctxObj)
    }
}

struct RepeatView: View {
    var key: String
    var element: UIElement
    var rep: RepeatConfig
    var spec: Spec
    var registry: Registry
    @ObservedObject var store: StateStore
    @ObservedObject var dispatcher: ActionDispatcher
    var functions: [String: @Sendable ([String: JSONValue]) -> JSONValue]
    var fallback: ((String) -> AnyView)?
    var outerItem: JSONValue?
    var outerIndex: Int?
    var outerArrayPath: String?
    var outerArrayIndex: Int?

    var body: some View {
        let outerCtx = store.evalContext(repeatItem: outerItem, repeatIndex: outerIndex, functions: functions)
        let items: [JSONValue] = {
            switch rep.statePath {
            case .path(let p): return getByPath(outerCtx.state, p)?.arrayValue ?? []
            case .itemField(let f):
                if let o = outerItem?.objectValue?[f]?.arrayValue { return o }
                return []
            }
        }()
        let myArrayPath: String? = {
            if case let .path(p) = rep.statePath { return p }
            return nil
        }()
        return AnyView(ForEach(Array(items.enumerated()), id: \.offset) { idx, it in
            let ctx = store.evalContext(repeatItem: it, repeatIndex: idx, functions: functions)
            if evaluateVisibility(element.visible, ctx: ctx) {
                SingleItemView(key: key, element: element, spec: spec, registry: registry, store: store, dispatcher: dispatcher, functions: functions, fallback: fallback, item: it, index: idx, arrayPath: myArrayPath, arrayIndex: idx)
            }
        })
    }
}

struct SingleItemView: View {
    var key: String
    var element: UIElement
    var spec: Spec
    var registry: Registry
    @ObservedObject var store: StateStore
    @ObservedObject var dispatcher: ActionDispatcher
    var functions: [String: @Sendable ([String: JSONValue]) -> JSONValue]
    var fallback: ((String) -> AnyView)?
    var item: JSONValue?
    var index: Int?
    var arrayPath: String?
    var arrayIndex: Int?

    var body: some View {
        var el = element
        el.repeatConfig = nil
        var tmpSpec = spec
        tmpSpec.elements["__single__\(key)__\(index ?? 0)"] = el
        return AnyView(ElementView(key: "__single__\(key)__\(index ?? 0)", spec: tmpSpec, registry: registry, store: store, dispatcher: dispatcher, functions: functions, fallback: fallback, item: item, index: index, arrayPath: arrayPath, arrayIndex: arrayIndex))
    }
}
