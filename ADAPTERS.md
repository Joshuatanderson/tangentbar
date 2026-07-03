# Adapter checklist

"Adapter" = whatever a target app class needs beyond the vanilla ladder
(`Extract/Extractor.swift`): a nudge, a different preferred rung, a quirk
workaround, or an exclusion. Status comes from spike/FINDINGS.md and live
`axspike watch` clicks — update rows as they're proven.

Rungs: `1` full AX (word+context) · `2` selection-only · `2b` value-only ·
`3a` copy-on-select pasteboard read · `3b` ⌘C synthesis · `none` → OCR (v3).

## App matrix

| Status | Target | Expected rung | Adapter notes |
|---|---|---|---|
| [x] proven | Chromium browsers (Brave) | 1 via selection | Lazy `AXEnhancedUserInterface` nudge per pid; never tree-walk. Point lookup may land on AXGroup/AXImage — selection path is primary. |
| [x] proven | Discord (Electron) | 1 | Works. Context clamps to the per-message `AXTextArea` → needs parent/sibling gathering (engine item below). |
| [x] proven | cmux / ghostty (GPU terminal) | 3a | ghostty copy-on-select writes the pasteboard at click time; read it, don't synthesize. |
| [ ] pending | Safari (WebKit) | 1 | Should be cleanest browser; verify — WebKit ≠ Chromium AX. |
| [ ] pending | Native Cocoa text (Notes, TextEdit, Mail) | 1 | Expected gold path; confirm with clicks. |
| [ ] pending | Slack (Electron) | 1 | Expect Discord-equivalent after nudge. |
| [ ] pending | Zed (GPUI custom) | 2/3b/none | Unknown — GPU-drawn editor; double-click does select, so 3b may rescue. |
| [ ] pending | Preview — text-layer PDF | 1 | Expect full AX; scanned/image PDFs are `none` (v3 OCR). |
| [ ] pending | Google Docs (canvas-rendered in browser) | 3b likely | Notorious: text is canvas-drawn, AX tree is a shim. High-value row — test early. |
| [ ] pending | Messages / Telegram | 1/2 | Native-ish; confirm. |
| [ ] pending | Terminal.app / iTerm2 | 1/3a | Terminal.app had decent AX historically; iTerm2 unknown; check copy-on-select defaults. |
| [ ] pending | Xcode / JetBrains IDEs | 1 / 2 | Xcode native (expect 1); JetBrains is JVM custom text (expect 2/3b). |
| [ ] verify | Password / secure fields | suppressed | `AXSecureTextField` bail is coded; verify with a real click, including that 3b never fires. |

## Engine work items (from proven rows)

- [x] **Latency: local-first tangent model.** DONE — LM Studio `qwen3.5-0.8b-mlx`
      via OpenAI-compatible SSE is the default (`Engine/SSEStream.swift`); measured
      0.16 s warm vs 7.6 s cold vs ~16 s `claude -p`. Prewarmed at launch +
      240 s keepalive. `claude -p haiku` is the automatic fallback when local is
      unreachable, and the quality option later.
- [ ] **True streaming for the claude fallback** — `--output-format stream-json`
      parsing (plain `-p` flushes mostly at once); the local SSE path already streams.
- [ ] **Context gathering for per-message elements** (Discord/Slack): when the hit
      element's text is small, pull sibling/parent `AXStaticText` for grounding.
- [ ] **Word fallback chain** — selection → range-word → first word of context →
      clipboard, so `word:` is never empty when context exists.
- [ ] **Multi-word phrases** — the app's double-click selection is source of truth;
      treat "word" as "clicked phrase" in prompt + panel title.
- [ ] **Pasteboard restore all flavors** (3b currently restores plain string only).
- [ ] **Copy-on-select ordering race** — 3a compares changeCount snapshotted at
      mouse-up; if the app copies *before* our tap sees the click, we misread. Track
      changeCount continuously instead.
- [ ] **`AXEnhancedUserInterface` side effects** — set lazily per pid (done), but add
      per-app gating + a way to un-set on quit; some apps animate resizes while it's on.
- [ ] **Per-app exclusions UI** (config key exists; menu/settings surface doesn't).

## App-shell work items

- [ ] Onboarding flow (permissions walk-through replacing the poll-timer; provider
      setup once, persisted — config file exists at
      `~/Library/Application Support/TangentBar/config.json`).
- [ ] Grab-selection flow (flow B): pill on selection + global hotkey (Carbon
      `RegisterEventHotKey`, no extra permission) → chat window seeded with excerpt.
- [ ] Chat window + follow-ups in the tangent panel (panel is read-only v0).
- [ ] Markdown hierarchy in `NSTextView` (AttributedString `PresentationIntent`
      mapping — the D4 investigation).
- [ ] `.app` bundle + `LSUIElement` + stable Developer ID signing (TCC keys the
      grant to the signature) + `SMAppService` login item + notarized DMG.
- [ ] Model picker in the status menu (static label today).
