import SwiftUI
import AppKit
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
        "submit": { params, set, state in
            if let valid = state["formResult"]?.objectValue?["valid"]?.boolValue, !valid {
                print("submit blocked: form validation failed")
                return
            }
            print("submit", params)
        },
        "loadCities": { params, set, _ in
            if case let .string(c) = params["country"] {
                set("/availableCities", c == "UK" ? .array([.string("London"), .string("Leeds")]) : .array([.string("New York"), .string("Austin")]))
            }
        },
        "navigate": { params, _, _ in
            guard case let .string(rawURL) = params["url"],
                  let parts = URLComponents(string: rawURL),
                  ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
                  parts.host != nil,
                  let url = parts.url else { return }
            NSWorkspace.shared.open(url)
        },
    ])
    @State private var spec: Spec? = nil
    @State private var prompt: String = "Revenue dashboard with todos, form, and metrics"
    @State private var isStreaming = false
    @State private var status: String = "Ready"
    @State private var mode: String = "local"
    @State private var streamLog: [String] = []
    @State private var generationTask: Task<Void, Never>?
    @State private var generationID = UUID()

    private var catalog: Catalog { zumiStandardCatalog() }

    var body: some View {
        HSplitView {
            VStack(spacing: 10) {
                HStack {
                    TextField("Describe UI…", text: $prompt).textFieldStyle(.roundedBorder)
                    Button(isStreaming ? "Stop" : "Generate") {
                        if isStreaming { stopGeneration() } else { startGeneration() }
                    }
                    .keyboardShortcut(.return)
                    Button("Reset", action: reset)
                    Picker("", selection: $mode) {
                        Text("Local").tag("local")
                        Text("OpenAI").tag("openai")
                        Text("Jev").tag("jev")
                    }.frame(width: 110)
                }
                Text(status).font(.caption).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                ScrollView {
                    Renderer(spec: spec, registry: zumiStandardRegistry(store: store, dispatcher: dispatcher), store: store, dispatcher: dispatcher, loading: isStreaming, catalog: catalog)
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
                List(Array(dispatcher.timeline.prefix(20).enumerated()), id: \.offset) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.element.name).font(.caption)
                        if let error = entry.element.error {
                            Text(error).font(.caption2).foregroundColor(.red)
                        }
                    }
                }.frame(height: 120)
                Spacer()
            }
            .padding()
            .frame(width: 300)
        }
        .onAppear {
            dispatcher.store = store
            refreshFormValidator(for: spec)
            store.onStateChange = { changes in
                guard let currentSpec = spec else { return }
                let matches = matchingWatches(spec: currentSpec, changedPaths: changes.map(\.path))
                Task { @MainActor in
                    for (_, _, bindings) in matches {
                        for binding in bindings {
                            await dispatcher.execute(binding, ctx: store.evalContext())
                        }
                    }
                }
            }
        }
        .onChange(of: spec) { _, updatedSpec in
            refreshFormValidator(for: updatedSpec)
        }
        .onReceive(NotificationCenter.default.publisher(for: .jrValidateForm)) { note in
            guard let valid = note.object as? Bool else { return }
            status = valid ? "Form valid" : "Form has errors"
        }
    }

    @MainActor
    func startGeneration() {
        stopGeneration(updateStatus: false)
        let id = UUID()
        generationID = id
        streamLog = []
        isStreaming = true
        generationTask = Task { await generate(id: id) }
    }

    @MainActor
    func stopGeneration(updateStatus: Bool = true) {
        generationTask?.cancel()
        generationTask = nil
        generationID = UUID()
        isStreaming = false
        if updateStatus { status = "Stopped — kept the last valid spec" }
    }

    @MainActor
    func reset() {
        stopGeneration(updateStatus: false)
        spec = nil
        streamLog = []
        status = "Ready"
    }

    @MainActor
    func refreshFormValidator(for currentSpec: Spec?) {
        dispatcher.formValidator = { state in
            guard let currentSpec else { return false }
            return validateFormState(spec: currentSpec, state: state)
        }
    }

    @MainActor
    func generate(id: UUID) async {
        let system = catalog.prompt(customRules: [
            "Use Card as the root for dashboards",
            "Prefer HStack for compact metrics",
            "Never invent components, props, or actions",
        ])
        let user = buildUserPrompt(prompt: prompt, currentSpec: spec, state: store.state)

        do {
            switch mode {
            case "local":
                status = "Generating the local demo…"
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
                    #"{"op":"add","path":"/elements/err","value":{"type":"Text","props":{"content":"Fix email to continue"},"visible":{"$state":"/form/email","eq":""}}}"#,
                    #"{"op":"add","path":"/elements/country","value":{"type":"Picker","props":{"label":"Country","value":{"$bindState":"/form/country"},"options":["US","UK"]},"watch":{"/form/country":{"action":"loadCities","params":{"country":{"$state":"/form/country"}}}}}}"#,
                    #"{"op":"add","path":"/elements/go","value":{"type":"Button","props":{"label":"Submit"},"on":{"press":[{"action":"validateForm","params":{"statePath":"/formResult"}},{"action":"submit","params":{}}]}}}"#,
                    #"{"op":"add","path":"/elements/adv","value":{"type":"Text","props":{"content":"Advanced on"},"visible":{"$state":"/showAdvanced"}}}"#,
                ]

                for line in lines {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 180_000_000)
                    guard let patch = parseSpecStreamLine(line), applySpecPatch(&demo, patch) else {
                        streamLog.append("Skipped invalid patch")
                        continue
                    }
                    streamLog.append(line)
                    if catalog.validate(spec: demo).isEmpty { spec = demo }
                }
                let issues = catalog.validate(spec: demo)
                guard id == generationID else { return }
                status = issues.isEmpty
                    ? "Demo ready — repeat, visibility, validation, watches, and templates are active"
                    : "Demo rejected — \\(issues.first?.message ?? "invalid spec")"

            case "openai":
                let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !key.isEmpty else {
                    status = "Set OPENAI_API_KEY to use OpenAI mode"
                    break
                }
                status = "Streaming from OpenAI…"
                let client = OpenAIStreamClient(config: .init(apiKey: key))
                let output = try await client.stream(system: system, user: user) { patch, candidate in
                    let line = (try? JSONEncoder().encode(patch))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "patch"
                    Task { @MainActor in
                        guard id == generationID else { return }
                        streamLog.append(line)
                        if isNonEmptySpec(candidate), catalog.validate(spec: candidate).isEmpty { spec = candidate }
                    }
                }
                try Task.checkCancellation()
                let issues = catalog.validate(spec: output)
                guard id == generationID else { return }
                if isNonEmptySpec(output), issues.isEmpty {
                    spec = output
                    status = "Done — UI validated"
                } else {
                    status = "Received an invalid spec — kept the last valid UI: \\(issues[0].message)"
                }

            case "jev":
                let environment = ProcessInfo.processInfo.environment
                let key = environment["JEV_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let endpoint = environment["JEV_API_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !key.isEmpty, let baseURL = URL(string: endpoint),
                      ["https", "http"].contains(baseURL.scheme?.lowercased() ?? ""),
                      baseURL.host != nil else {
                    status = "Configure JEV_API_KEY and JEV_API_URL to use Jev mode"
                    break
                }
                status = "Requesting a Jev snapshot…"
                let client = JevClient(config: .init(apiKey: key, baseURL: baseURL))
                let result = try await client.compose(
                    catalog: catalog,
                    candidates: jevCandidates(from: catalog),
                    prompt: user,
                    initialState: store.state,
                    initialSpec: spec
                ) { snapshot in
                    Task { @MainActor in
                        guard id == generationID else { return }
                        if isNonEmptySpec(snapshot), catalog.validate(spec: snapshot).isEmpty {
                            spec = snapshot
                            streamLog.append("Jev snapshot replaced the current spec")
                        }
                    }
                }
                try Task.checkCancellation()
                guard id == generationID else { return }
                switch result.stop {
                case .finish:
                    if let snapshot = result.spec, isNonEmptySpec(snapshot), catalog.validate(spec: snapshot).isEmpty {
                        spec = snapshot
                        status = "Jev finished — snapshot validated"
                    } else {
                        status = "Jev returned an invalid spec — kept the last valid UI"
                    }
                case .limit:
                    status = "Jev reached its step limit — kept the last valid UI"
                case .unavailable:
                    status = "Jev did not return a usable spec — kept the last valid UI"
                }

            default:
                status = "Choose Local, OpenAI, or Jev mode"
            }
        } catch is CancellationError {
            guard id == generationID else { return }
            status = "Stopped — kept the last valid spec"
        } catch {
            guard id == generationID else { return }
            status = "Error: \\(error.localizedDescription) — kept the last valid spec"
        }

        guard id == generationID else { return }
        generationTask = nil
        isStreaming = false
    }

    func pretty(_ state: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(state)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
