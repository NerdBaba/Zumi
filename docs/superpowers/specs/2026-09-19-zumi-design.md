# zumi — Safe Generative UI for macOS — Design

Date: 2026-09-19
Status: draft, pending user review
Project: zumi (Swift macOS, SwiftUI)
Approach: B Layered (approved)

## 1. Goal
Native macOS app that generates safe components following json-render workflow:
define catalog (vocab) -> AI generates spec (JSON) -> registry renders natively.
No arbitrary code execution. AI chooses structure; app controls components, props, actions.

Spec sources: OpenAI Completions API (streaming, JSONL patches) + TypeSafe Jev decision API (snapshots).

## 2. Architecture (§1 approved)
- `JRCore` (pure Swift, no SwiftUI): `Spec/Element/ActionBinding/VisibilityCondition` as `Codable`; `Catalog`; JSON Pointer get/set (RFC6901); `evaluateVisibility`; `resolveValue` (`$state/$item/$index/$cond/$template/$computed`); `SpecStreamCompiler` (RFC6902 add/replace/remove/move/copy/test); `ValidationEngine`; `WatchEngine`.
- `JRSwiftUI`: `StateStore: ObservableObject` (`get/set/update`, `@MainActor`); `Registry` via `defineRegistry`; `Renderer` (root -> children/slots); `ComponentContext(props,children,slots,emit,bindings)`; providers as `EnvironmentObjects` (`StateProvider`, `VisibilityProvider`, `ActionProvider`, `ValidationProvider` / `JSONUIProvider` convenience).
- `JRClients`: `OpenAIStreamClient` (SSE -> JSONL -> compiler) + `JevClient` (candidates, `composeSpec`, batch/sequential, budgets `maxSteps/maxElements/maxDepth`).
- App target: prompt box -> client -> `spec` -> `Renderer(registry)` + inspector (spec/state/actions/stream/catalog panels, devtools parity).

## 3. Catalog (§2 approved)
Layout: `VStack/HStack/ZStack` (spacing,alignment,padding), `Grid` (columns), `Card` (title,subtitle -> GroupBox), `Section` (header), `Divider`, `Spacer`, `ScrollView`, `Tabs` (TabView), `Table` (key).
Primitives: `Text(content,variant)`, `Image(src,alt)`, `Badge(label)`, `Progress(value)`.
Inputs: `TextField(value,placeholder)`, `SecureField`, `TextArea`, `Toggle(checked,label)`, `Checkbox`, `Slider(value,min,max)`, `Picker(value,options)`, `DatePicker`, `Button(label,variant)` + `events:[press]`, `Form`.
Props: `Codable + validator` (Zod parity), optional = nullable, enums closed.
Slots: `children` = default, `slots:{header,footer}` for Card/Section/Form.
Actions v1: built-in `setState/pushState/removeState/validateForm` + custom `submit/navigate/openURL/fetch`.
Functions v1: `fullName/formatCurrency` examples, extensible.

## 4. Runtime behaviors (all v1)
- Data binding: `$state`, `$item`/`$index` in repeat only, `$bindState` on value/checked/pressed, `$bindItem` in repeat, `repeat:{statePath,key}` -> `ForEach`. Missing path -> nil/empty. Type mismatch -> validation issue + fallback.
- Visibility: truthy, `not`, single `eq/neq/gt/gte/lt/lte` (precedence eq>neq>gt>gte>lt>lte), `[..]` AND, `$or`, `$and` nested only, booleans, `$item/$index` scope, filter-on-container. Auth as `/auth/isSignedIn`.
- Actions: intent names, params resolve expressions, async handlers `(params,setState,state)`, `confirm/onSuccess/onError/preventDefault`.
- Validation: `checks:{type,args,message}`, built-ins required/email/minLength/maxLength/pattern/min/max/numeric/url/matches/equalTo/lessThan/greaterThan/requiredIf, `validateOn:change|blur|submit`, `enabled` condition, cross-field via `$state`, `validateForm` writes `{valid}`, submit not auto-gated.
- Watch+computed: top-level `watch:{path:action|[actions]}`, fires on `===` change only, sequential; `$template:${/path}` missing->"", `$computed:fn(args)` pure.
- Streaming: OpenAI JSONL patches progressive + loading skeleton, `send` aborts prior, `clear` resets; Jev full snapshots replace.

## 5. Data flow (§3 approved)
- `Catalog.prompt(customRules,mode)` -> system prompt. Modes: standalone JSONL-only, inline text+JSONL. `buildUserPrompt(prompt,currentSpec,state)` for refinement.
- OpenAI: `chat/completions stream:true` -> SSE -> lines -> `compiler.push()` -> `@Published spec` -> Renderer.
- Jev: candidates from local records -> `composeSpec` -> `step` replace -> `complete{finish|limit|unavailable}`. Batch new (root+select, layout), sequential edits.
- Loop: read via `get`, write via `set/update`, re-evaluate visibility/computed/validation/watchers on MainActor.

## 6. Error handling + testing (§4 approved)
- Fail-closed validation (`validateSpec`, cycles/shared-children/dangling/unknown-type/bad-scope reject). Unknown type -> fallback view + log.
- Stream malformed/abort/test-fail -> keep last good, flag incomplete. Jev limit/unavailable/null -> retain prior + status.
- Unknown action -> noop + timeline. Handler throw -> onError. Watch cycle -> depth-cap. Async validation race -> latest-wins. MainActor writes.
- Tests: JRCore unit (pointer, visibility table, stream suite, validation matrix, watch guard) + JRSwiftUI snapshots per component + progressive + Jev replace.

## 7. Out of scope v1
Custom schema beyond flat spec, code export, image/pdf/video renderers, external store adapters (Redux/Zustand), server-assisted mode, i18n directives beyond `$template`.

## 8. Open decisions
- OpenAI model id + key storage (Keychain vs env).
- Jev Gateway endpoint + auth.
- Minimum macOS version (propose 14+ for SwiftUI Grid/Table).
- Inline mode prose rendering in chat UI: yes/no v1.
