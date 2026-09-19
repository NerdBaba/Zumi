import Foundation

// MARK: - Watchers: fire actions when watched paths change (any source)

/// Returns watch bindings whose path matches one of the changed paths.
public func matchingWatches(spec: Spec, changedPaths: [String]) -> [(element: UIElement, path: String, bindings: [ActionBinding])] {
    var out: [(UIElement, String, [ActionBinding])] = []
    for el in spec.elements.values {
        guard let watch = el.watch else { continue }
        for (path, binding) in watch where changedPaths.contains(path) {
            out.append((el, path, binding.all))
        }
    }
    return out
}

/// Form-level validation aggregation: all elements with `checks` must pass.
public func validateFormState(spec: Spec, state: [String: JSONValue], ctxFunctions: [String: @Sendable ([String: JSONValue]) -> JSONValue] = standardFunctions) -> Bool {
    for el in spec.elements.values {
        guard let checksRaw = el.props["checks"], !checksFromProp(checksRaw).isEmpty else { continue }
        // Skip hidden elements
        let ctx = EvalContext(state: state, functions: ctxFunctions)
        if !evaluateVisibility(el.visible, ctx: ctx) { continue }
        // Find bound value: value/checked/pressed with $bindState
        var boundPath: String?
        var boundValue: JSONValue = .null
        for key in ["value", "checked", "pressed"] {
            if let raw = el.props[key] {
                let r = resolvePropValue(raw, ctx: ctx)
                if let b = r.bindingPath, !b.hasPrefix("$item:") {
                    boundPath = b; boundValue = r.value; break
                } else if r.bindingPath == nil, boundPath == nil {
                    boundValue = r.value
                }
            }
        }
        // Conditional enable
        if let enabledRaw = el.props["enabled"] {
            let er = resolvePropValue(enabledRaw, ctx: ctx).value
            if er == .bool(false) { continue }
        }
        let checks = checksFromProp(checksRaw)
        let errors = validateField(value: boundValue, checks: checks, state: state)
        if !errors.isEmpty { return false }
        _ = boundPath
    }
    return true
}
