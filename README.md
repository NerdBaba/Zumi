# zumi — Safe Generative UI for macOS

SwiftUI macOS app implementing the json-render workflow: catalog (vocab) → AI spec (JSON/JSONL) → registry (native views). No code exec; AI declares intent, app implements handlers.

## Run
- OpenAI mode: `OPENAI_API_KEY=... swift run Zumi` (macOS 14+, Xcode 26).
- Local demo (no key): launch, keep mode `Local`, press Generate — streams repeat + `$template` + validation + watch + visibility demo.
- Tests: `swift test`. Build: `swift build`.

## Layout
- `Sources/JRCore`: `Spec`, `JSONPointer` (RFC6901), `Evaluation` (`$state/$item/$index/$cond/$template/$computed`, visibility), `Catalog` + `zumiStandardCatalog`, `SpecStream` (RFC6902 compiler, merge/diff), `Validation`, `WatchForm`.
- `Sources/JRSwiftUI`: `StateStore` (`@MainActor`), `Registry` + `zumiStandardRegistry`, `Renderer` (repeat-aware `$bindItem` writes, filtered visibility).
- `Sources/JRClients`: `OpenAIStreamClient` (SSE → JSONL), `JevClient` (snapshot replace, never merged as patches), `buildUserPrompt`.
- `Sources/Zumi`: `ZumiApp` + inspector (state/stream/actions).

## Safety
Fail-closed `catalog.validate()` before render; unknown type → fallback; `send` aborts prior stream; watch fires on `===` change only; `validateForm` writes `{valid}` but never auto-blocks submit — guard explicitly.
