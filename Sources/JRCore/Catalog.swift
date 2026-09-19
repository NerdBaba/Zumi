import Foundation

// MARK: - Catalog (vocabulary + guardrail)

public struct ComponentDefinition: Sendable {
    public var description: String?
    public var slots: [String]
    public var events: [String]
    public var propNames: [String]
    public var validateProps: @Sendable ([String: JSONValue]) -> [String]

    public init(description: String? = nil, slots: [String] = [], events: [String] = [], propNames: [String] = [], validateProps: @Sendable @escaping ([String: JSONValue]) -> [String] = { _ in [] }) {
        self.description = description
        self.slots = slots
        self.events = events
        self.propNames = propNames
        self.validateProps = validateProps
    }
}

public struct ActionDefinition: Sendable {
    public var description: String?
    public var paramNames: [String]
    public init(description: String? = nil, paramNames: [String] = []) {
        self.description = description
        self.paramNames = paramNames
    }
}

public struct Catalog: Sendable {
    public var components: [String: ComponentDefinition]
    public var actions: [String: ActionDefinition]
    public var functions: [String: String] // name -> description

    public init(components: [String: ComponentDefinition], actions: [String: ActionDefinition] = [:], functions: [String: String] = [:]) {
        self.components = components
        self.actions = actions
        self.functions = functions
    }

    public var componentNames: [String] { Array(components.keys).sorted() }
    public var actionNames: [String] { Array(actions.keys).sorted() }

    public func validate(spec: Spec) -> [SpecIssue] {
        var issues = validateSpec(spec).issues
        for (key, el) in spec.elements {
            guard let def = components[el.type] else {
                issues.append(.init(path: "/elements/\(key)/type", message: "Unknown component '\(el.type)'"))
                continue
            }
            // slots
            for slot in (el.slots ?? [:]).keys where !def.slots.contains(slot) && slot != "default" {
                issues.append(.init(path: "/elements/\(key)/slots/\(slot)", message: "Unknown slot '\(slot)' for '\(el.type)'"))
            }
            if (el.children?.isEmpty == false), !def.slots.contains("default") {
                issues.append(.init(path: "/elements/\(key)/children", message: "'\(el.type)' does not accept default slot"))
            }
            for m in def.validateProps(el.props) {
                issues.append(.init(path: "/elements/\(key)/props", message: m))
            }
            // actions
            for (event, binding) in (el.on ?? [:]) {
                if !def.events.contains(event) {
                    issues.append(.init(path: "/elements/\(key)/on/\(event)", message: "Undeclared event '\(event)' for '\(el.type)'"))
                }
                for b in binding.all where actions[b.action] == nil && !BuiltinActions.contains(b.action) {
                    issues.append(.init(path: "/elements/\(key)/on/\(event)", message: "Unknown action '\(b.action)'"))
                }
            }
            for (path, binding) in (el.watch ?? [:]) {
                for b in binding.all where actions[b.action] == nil && !BuiltinActions.contains(b.action) {
                    issues.append(.init(path: "/elements/\(key)/watch[\(path)]", message: "Unknown action '\(b.action)'"))
                }
            }
        }
        return issues
    }

    public func prompt(mode: PromptMode = .standalone, customRules: [String] = []) -> String {
        var lines: [String] = []
        lines.append(mode == .standalone
            ? "Output ONLY JSONL patches (RFC6902), one per line. No prose."
            : "Respond conversationally, then JSONL patches on their own lines when UI is needed. Text-only replies allowed.")
        lines.append("Components:")
        for name in componentNames {
            let d = components[name]!
            let props = d.propNames.joined(separator: ",")
            let slots = d.slots.joined(separator: ",")
            let events = d.events.joined(separator: ",")
            lines.append("- \(name): \(d.description ?? "") props=[\(props)] slots=[\(slots)] events=[\(events)]")
        }
        let builtin = ["setState", "pushState", "removeState", "validateForm"] + actionNames
        lines.append("Actions: " + builtin.joined(separator: ","))
        if !functions.isEmpty { lines.append("Functions: " + functions.map { $0.key + ": " + $0.value }.joined(separator: "; ")) }
        lines.append("Expressions: {\"$state\":\"/path\"}, {\"$item\":\"field\"}, {\"$index\":true}, {\"$bindState\":\"/path\"}, {\"$bindItem\":\"field\"}, {\"$cond\":c,\"$then\":a,\"$else\":b}, {\"$template\":\"Hi ${/name}\"}, {\"$computed\":\"fn\",\"args\":{}}")
        lines.append("Visibility: {\"$state\":\"/p\"}, {not}, {eq|neq|gt|gte|lt|lte}, [AND], {\"$or\":[]}, {\"$and\":[]} nested, {\"$item\"}, {\"$index\":true}, true/false")
        for r in customRules { lines.append("Rule: \(r)") }
        return lines.joined(separator: "\n")
    }
}

public enum PromptMode: Sendable { case standalone, inline }
public let BuiltinActions: Set<String> = ["setState", "pushState", "removeState", "validateForm"]

// MARK: - Standard functions ($computed)

public let standardFunctions: [String: @Sendable ([String: JSONValue]) -> JSONValue] = [
    "fullName": { args in
        let f = args["first"]?.stringValue ?? ""
        let l = args["last"]?.stringValue ?? ""
        return .string("\(f) \(l)".trimmingCharacters(in: .whitespaces))
    },
    "formatCurrency": { args in
        let v = args["value"]?.doubleValue ?? 0
        let f = NumberFormatter(); f.numberStyle = .currency; f.currencyCode = args["currency"]?.stringValue ?? "USD"
        return .string(f.string(from: NSNumber(value: v)) ?? "\(v)")
    },
]

// MARK: - Standard catalog (Core + layout, macOS)

@Sendable private func reqProps(_ props: [String: JSONValue], _ fields: [String]) -> [String] {
    fields.filter { f in
        guard let v = props[f] else { return true }
        return v.isNull
    }.map { "Missing required prop '\($0)'" }
}

public func zumiStandardCatalog() -> Catalog {
    return Catalog(
        components: [
            "VStack": .init(description: "Vertical stack", slots: ["default"], propNames: ["spacing", "alignment", "padding"]),
            "HStack": .init(description: "Horizontal stack", slots: ["default"], propNames: ["spacing", "alignment", "padding"]),
            "ZStack": .init(description: "Overlay stack", slots: ["default"], propNames: ["alignment"]),
            "Grid": .init(description: "Multi-column grid", slots: ["default"], propNames: ["columns", "spacing"]),
            "Card": .init(description: "Grouped container", slots: ["default", "header", "footer"], propNames: ["title", "subtitle"]),
            "Section": .init(description: "Form section", slots: ["default", "header", "footer"], propNames: ["header"]),
            "Form": .init(description: "Form container", slots: ["default"], propNames: ["title"]),
            "Tabs": .init(description: "Tab view", slots: ["default"], propNames: ["selection"]),
            "List": .init(description: "List container", slots: ["default"], propNames: ["style"]),
            "Table": .init(description: "Data table", slots: ["default"], propNames: ["columns"]),
            "ScrollView": .init(description: "Scrollable region", slots: ["default"], propNames: ["axes"]),
            "Text": .init(description: "Text", propNames: ["content", "variant"], validateProps: { reqProps($0, ["content"]) }),
            "Heading": .init(description: "Heading", propNames: ["text", "level"], validateProps: { reqProps($0, ["text"]) }),
            "Image": .init(description: "Image", propNames: ["src", "alt"]),
            "Divider": .init(description: "Divider", propNames: []),
            "Spacer": .init(description: "Spacer", propNames: ["minLength"]),
            "Badge": .init(description: "Badge", propNames: ["label"], validateProps: { reqProps($0, ["label"]) }),
            "Progress": .init(description: "Progress", propNames: ["value", "total"]),
            "Button": .init(description: "Button", events: ["press"], propNames: ["label", "variant"], validateProps: { reqProps($0, ["label"]) }),
            "TextField": .init(description: "Text input", events: ["change", "blur", "submit"], propNames: ["value", "placeholder", "label", "checks", "validateOn"]),
            "SecureField": .init(description: "Password input", events: ["change", "blur"], propNames: ["value", "placeholder", "label", "checks"]),
            "TextArea": .init(description: "Multiline input", events: ["change"], propNames: ["value", "placeholder", "label"]),
            "Toggle": .init(description: "Toggle switch", events: ["change"], propNames: ["checked", "label"]),
            "Checkbox": .init(description: "Checkbox", events: ["change"], propNames: ["checked", "label"]),
            "Slider": .init(description: "Slider", events: ["change"], propNames: ["value", "min", "max"]),
            "Picker": .init(description: "Picker", events: ["change"], propNames: ["value", "options", "label"]),
            "DatePicker": .init(description: "Date picker", events: ["change"], propNames: ["value", "label"]),
        ],
        actions: [
            "submit": .init(description: "Submit form", paramNames: ["formId"]),
            "navigate": .init(description: "Open URL", paramNames: ["url"]),
            "fetch": .init(description: "Fetch data", paramNames: ["endpoint", "target"]),
        ],
        functions: ["fullName": "Combine first+last", "formatCurrency": "Format number as currency"]
    )
}
