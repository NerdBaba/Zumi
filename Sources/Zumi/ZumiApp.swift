import SwiftUI
import JRCore
import JRSwiftUI
import JRClients

@main
struct ZumiApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 980, minHeight: 680)
        }
    }
}

struct ContentView: View {
    @StateObject private var store = StateStore(initialState: [
        "user": .object(["name": .string("Ada")]),
        "todos": .array([
            .object(["id": .string("1"), "title": .string("Buy milk"), "done": .bool(false)]),
            .object(["id": .string("2"), "title": .string("Walk dog"), "done": .bool(true)]),
        ]),
        "form": .object(["email": .string(""), "country": .string("US")]),
        "availableCities": .array([.string("New York"), .string("Austin")]),
        "showAdvanced": .bool(false),
    ])
    @StateObject private var dispatcher = ActionDispatcher(handlers: [
        "submit": { params, set, _ in print("submit", params) },
        "loadCities": { params, set, _ in
            if case let .string(c) = params["country"] {
                set("/availableCities", c == "UK" ? .array([.string("London"), .string("Leeds")]) : .array([.string("New York"), .string("Austin")]))
            }
        },
        "navigate": { params, _, _ in
            if case let .string(url) = params["url"], let u = URL(string: url) {
                #if os(macOS)
                NSWorkspace.shared.open(u)
                #endif
            }
        },
    ])
    @State private var spec: Spec? = nil
    @State private var prompt: String = "Revenue dashboard with todos, form, and metrics"
    @State private var isStreaming = false
    @State private var status: String = "Ready"
    @State private var mode: String = "local"
    @State private var streamLog: [String] = []

    private var catalog: Catalog { zumiStandardCatalog() }

    var body: some View {
        HSplitView {
            VStack(spacing: 10) {
                HStack {
                    TextField("Describe UI…", text: $prompt).textFieldStyle(.roundedBorder)
                    Button(isStreaming ? "Stop" : "Generate") { Task { await generate() } }
                        .keyboardShortcut(.return)
                    Button("Reset") { spec = nil; streamLog = [] }
                    Picker("", selection: $mode) {
                        Text("Local").tag("local")
                        Text("OpenAI").tag("openai")
                        Text("Jev").tag("jev")
                    }.frame(width: 110)
                }
                Text(status).font(.caption).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                ScrollView {
                    Renderer(spec: spec, registry: zumiStandardRegistry(store: store, dispatcher: dispatcher), store: store, dispatcher: dispatcher, loading: isStreaming)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding()
            .frame(minWidth: 600)
            VStack(alignment: .leading, spacing: 8) {
                Text("Inspector").font(.headline)
                Text("State").font(.caption.bold())
                ScrollView { Text(pretty(store.state)).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 170)
                Text("Stream").font(.caption.bold())
                List(streamLog.suffix(30), id: \.self) { Text($0).font(.system(.caption, design: .monospaced)) }.frame(height: 180)
                Text("Actions").font(.caption.bold())
                List(dispatcher.timeline.prefix(20), id: \.name) { Text($0.name).font(.caption) }.frame(height: 120)
                Spacer()
            }
            .padding()
            .frame(width: 300)
        }
        .onAppear {
            dispatcher.store = store
            store.onStateChange = { changes in
                guard let spec else { return }
                let paths = changes.map(\.path)
                let matches = matchingWatches(spec: spec, changedPaths: paths)
                for (_, _, bindings) in matches {
                    for b in bindings {
                        let ctx = store.evalContext()
                        Task { @MainActor in await dispatcher.execute(b, ctx: ctx) }
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .jrValidateForm)) { note in
            let target = (note.object as? String) ?? "/formValidation"
            guard let spec else { return }
            let ok = validateFormState(spec: spec, state: store.state)
            store.set(target, .object(["valid": .bool(ok)]))
            status = ok ? "Form valid" : "Form has errors"
        }
    }

    func generate() async {
        if isStreaming { isStreaming = false; status = "Stopped — kept last good spec"; return }
        let system = catalog.prompt(customRules: ["Use Card as root for dashboards", "Prefer HStack for metrics"])
        let user = buildUserPrompt(prompt: prompt, currentSpec: spec, state: store.state)
        if mode == "local" {
            isStreaming = true; status = "Generating (local demo stream)…"
            var demo = Spec()
            let lines = [
                #"{"op":"add","path":"/root","value":"root"}"#,
                #"{"op":"add","path":"/elements/root","value":{"type":"VStack","props":{},"children":["hello","list","form","adv"]}}"#,
                #"{"op":"add","path":"/elements/hello","value":{"type":"Text","props":{"content":{"$template":"Hello ${/user/name}! You have 2 todos."}}}}"#,
                #"{"op":"add","path":"/elements/list","value":{"type":"VStack","props":{},"repeat":{"statePath":"/todos","key":"id"},"children":["row"]}}"#,
                #"{"op":"add","path":"/elements/row","value":{"type":"HStack","props":{},"children":["t","done"]}}"#,
                #"{"op":"add","path":"/elements/t","value":{"type":"Text","props":{"content":{"$item":"title"}}}}"#,
                #"{"op":"add","path":"/elements/done","value":{"type":"Toggle","props":{"label":"Done","checked":{"$bindItem":"done"}}}}"#,
                #"{"op":"add","path":"/elements/form","value":{"type":"Card","props":{"title":"Signup"},"children":["email","err","country","go"]}}"#,
                #"{"op":"add","path":"/elements/email","value":{"type":"TextField","props":{"label":"Email","value":{"$bindState":"/form/email"},"placeholder":"you@acme.com","checks":[{"type":"required","message":"Email required"},{"type":"email","message":"Invalid email"}]}}}"#,
                #"{"op":"add","path":"/elements/err","value":{"type":"Text","props":{"content":"Fix email to continue"},"visible":{"$state":"/form/email","eq":""}}}}"#,
                #"{"op":"add","path":"/elements/country","value":{"type":"Picker","props":{"label":"Country","value":{"$bindState":"/form/country"},"options":["US","UK"]},"watch":{"/form/country":{"action":"loadCities","params":{"country":{"$state":"/form/country"}}}}}}"#,
                #"{"op":"add","path":"/elements/go","value":{"type":"Button","props":{"label":"Submit"},"on":{"press":[{"action":"validateForm","params":{"statePath":"/formResult"}},{"action":"submit","params":{}}]}}}"#,
                #"{"op":"add","path":"/elements/adv","value":{"type":"Text","props":{"content":"Advanced on"},"visible":{"$state":"/showAdvanced"}}}"#,
            ]
            for l in lines {
                if !isStreaming { break }
                try? await Task.sleep(nanoseconds: 220_000_000)
                if let p = parseSpecStreamLine(l), applySpecPatch(&demo, p) {
                    await MainActor.run { spec = demo; streamLog.append(l) }
                }
            }
            let issues = catalog.validate(spec: demo)
            await MainActor.run {
                isStreaming = false
                status = issues.isEmpty ? "Done — all features live: repeat, visibility, validation, watch, template" : "Done — \(issues.count) issues: \(issues.prefix(2).map(\.message).joined(separator: "; "))"
            }
            return
        }
        guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], mode == "openai" else {
            status = mode == "jev" ? "Jev needs gateway key — set JEV_API_KEY (demo skipped)" : "Set OPENAI_API_KEY to use OpenAI mode"
            return
        }
        isStreaming = true; status = "Streaming from OpenAI…"
        do {
            let client = OpenAIStreamClient(config: .init(apiKey: key))
            let out = try await client.stream(system: system, user: user) { _, s in
                Task { @MainActor in spec = s }
            }
            spec = out
            status = "Done — \(catalog.validate(spec: out).count) issues"
        } catch {
            status = "Error: \(error.localizedDescription) — kept last good spec"
        }
        isStreaming = false
    }

    func pretty(_ s: [String: JSONValue]) -> String {
        (try? JSONEncoder().encode(s)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
