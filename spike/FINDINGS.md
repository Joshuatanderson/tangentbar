# Extraction spike — findings (2026-07-02)

Automated phase, run live against Josh's actual session (no focus theft, no synthetic
input). Binary: `spike/axspike` (`swiftc -O -o axspike axspike.swift`).

## Confirmed working

- **AX trust**: the cmux/ghostty process chain already carries the Accessibility grant —
  `axspike check` → trusted. The spike tap creates successfully.
- **Element-at-point** (`AXUIElementCopyElementAtPosition`) resolves into web content:
  grid probes over Brave returned page-level roles (`AXStaticText`, `AXGroup`, `AXImage`)
  with correct app attribution.
- **Parameterized attributes work where it matters**: `AXRangeForPosition` +
  `AXStringForRange` returned real text on native-backed fields (Brave omnibox,
  chars=118 URL, correct round-trip).
- **Focused-element path reaches web content**: `axspike focused` on Brave returned
  `AXWebArea` with rung-1 (full parameterized) support. This is the primary double-click
  path — the click natively selects the word, then we read `AXSelectedText` +
  `AXSelectedTextRange` and pull context around the range.
- **Non-text under cursor is correctly refused** (AXImage → ladder none), and
  `AXSecureTextField` is suppressed by design.

## Gotchas found (each one a design input)

1. **System-wide `AXFocusedUIElement` is flaky** — returned nothing while the
   frontmost-app path (`AXUIElementCreateApplication(frontmost.pid)` → focused element)
   worked. Real app: always resolve via the frontmost application.
2. **Chromium's deep AX tree does not materialize from the nudge alone.** Setting
   `AXEnhancedUserInterface`/`AXManualAccessibility` did not surface `AXWebArea` in a
   BFS from `AXWindows` (tree bottoms out ~600 nodes, no web area role). But hit-testing
   and the focused-element path DO reach web content. Conclusion: never walk trees at
   runtime; use element-at-point and focused-element exclusively.
3. **AX only sees windows on the current Space** — `AXWindows` returned `[]` for Notes,
   Slack, Zed, cmux, Preview, Messages (all running, windows elsewhere/hidden). Fine for
   the product (you interact with what you see) but rules out any background pre-indexing.
4. **Point-lookup vs selection-lookup are complementary.** Point lookup can land on a
   non-text child (image/group) even when a word was click-selected. Watch mode now tries
   both and prefers whichever produced a word.
5. **`AXEnhancedUserInterface` has known side effects** (some window managers/apps show
   resize jank while it's set). The real app should set it lazily, per-app, only after
   rung 1+2 fail, and it should be visible in a per-app compatibility setting.

## Interactive matrix (Josh driving, 2026-07-03)

| App | Category | Result |
|---|---|---|
| Brave | Chromium web | `1-full-ax` via focused `AXWebArea` + selection; `2-selection-only` seen on an `AXGroup` |
| Discord | Electron | **`1-full-ax`** on `AXTextArea` — word + context(53). Electron works. |
| cmux (ghostty) | GPU terminal | **`3a-copy-on-select`** — ghostty copies on select; word read straight off the pasteboard, no ⌘C synthesis needed |

Feasibility across the three hardest categories (web, Electron, GPU terminal) is
**proven**. Remaining rows are confirmatory, not existential.

### Extraction-quality bugs for the real engine (from the Discord rows)

- **Context clamped to the element**: Discord renders one small `AXTextArea` per
  message, so the ±400 window clamps to ~the message itself (`context(8): in that`).
  Engine fix: when the element's text is tiny, gather sibling/parent text for broader
  grounding (or accept message-granularity context in chat apps).
- **Empty word with good context**: one row had `word:` blank — `wordAround` landed on
  a non-word char and `AXSelectedText` was empty by the time we read it. Engine fix:
  fall back word ← first word of the selection range's text, then ← clipboard.
- **Multi-word "word"** (`in that`): the app's own double-click selection is the source
  of truth and sometimes exceeds one word; treat "word" as "clicked phrase" — fine for
  the tangent prompt.

## Open — remaining confirmatory rows

Run `./axspike watch` in a visible terminal pane, then double-click words across daily
apps and eyeball the output lines (`ladder:` rung + `word:` + `context:`):

- [ ] Brave — web page body text (expect rung 1 via selection)
- [ ] Notes (native Cocoa — expect rung 1)
- [ ] Slack (Electron — expect nudge note then rung 1/2)
- [ ] Zed (GPU UI — unknown, may be ladder none → clipboard rung territory)
- [ ] cmux/ghostty terminal text (unknown)
- [ ] Preview PDF (expect rung 1 on text-layer PDFs)
- [ ] Messages / Telegram
- [ ] A password field (expect "secure field — suppressed")

Rung legend: `1-full-ax` word+context · `2-selection-only` word, no context ·
`2-selection+value` / `2b-value-only` context from whole value · `none` → clipboard
synthesis (not implemented in spike) or OCR (v3).
