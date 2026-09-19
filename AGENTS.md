# AGENTS.md — zumi

Native macOS SwiftUI app for safe generative UI (json-render workflow). AI picks structure; app controls catalog/registry. No `eval`, no arbitrary code exec.

## Source of truth
- Design: `docs/superpowers/specs/2026-09-19-zumi-design.md` (§1–§4 approved). Trust it over issues/chat.
- No scaffold yet: no `Package.swift`, `.xcodeproj`, CI, or tests. Verify before running `xcodebuild`/`swift build`.

## Architecture (Layered B)
- `JRCore` (pure Swift, no SwiftUI): `Spec` flat `{root, elements}`, `Catalog`, JSON Pointer (RFC6901) get/set, `evaluateVisibility`, `resolveValue` (`$state/$item/$index/$cond/$template/$computed`), SpecStream compiler (RFC6902), validation + watch engines.
- `JRSwiftUI`: `StateStore: ObservableObject` (`@MainActor`), `Registry` via `defineRegistry`, `Renderer`, `ComponentContext`, env providers.
- `JRClients`: `OpenAIStreamClient` (SSE → JSONL patches → progressive spec) vs `JevClient` (candidate pick → full snapshot replace). Never merge Jev snapshots as patches.

## Setup
- Requires Xcode + macOS SDK (propose macOS 14+ for `Grid`/`Table`; unconfirmed — check open decisions in design §8 before scaffolding).
- Keys (`OPENAI_API_KEY`, Jev Gateway endpoint/auth) server-side or Keychain; never hardcode. Storage decision still open.

## Gotchas
- Fail closed: `catalog.validate()`/`validateSpec()` before render (dangling ids, cycles, shared children, unknown type, `$item` outside repeat). Unknown type → fallback view + log, never crash.
- One visibility operator per condition; precedence `eq>neq>gt>gte>lt>lte`. `send` aborts prior stream; keep last good spec flagged incomplete. Watch fires on `===` change only, cap cycles. Async validation latest-wins. All store writes `@MainActor`.
- `validateForm` writes `{valid}` but does not block submit — guard explicitly.

## Implementation plan
- Built v1 per design §1–§4: `swift build` + `swift test` (6 JRCore tests) green. Local demo in `Sources/Zumi` exercises all runtime behaviors. See `README.md` for run/test.
