# Tangent v2 — decisions of record

Reviewed via `architecture.html` export, 2026-07-02 (MDT). Josh's picks + notes, plus
the one follow-up call his notes reopened.

## Decisions

| # | Decision | Call | Notes |
|---|----------|------|-------|
| D1 | Process architecture | **Swift-only, single app** (supersedes the exported `swift-shell-rust-daemon` pick — see below) | One language, one process, no IPC. Keep v1's discipline via an internal UI-free `TangentEngine` module. |
| D2 | Tangent trigger | **Bare double-click on a word → pill affordance**, configurable | Josh: simplest UX wins; modifier (⌥) available as a setting, not the default. |
| D3 | Grab-selection trigger | **Selection pill AND global hotkey — support both** | Josh: hotkeys alone kill adoption ("I'm still not using Raycast"). Pill is primary; hotkey for power use. |
| D4 | Popup + chat rendering | **Native NSTextView / AttributedString** | Speed first; we're Mac-native anyway. Investigate how AppKit maps markdown hierarchy (headings arrive as `PresentationIntent`s that must be mapped to fonts manually). |
| D5 | Core reuse | **Fresh rewrite, in this repo (`tangent-2`), lessons from v1 carried as spec** | v1 stays frozen as reference. Language: see D1 — Swift. |
| D6 | First milestone | **Extraction spike** (`spike/axspike.swift`) | Prove AX text-at-point feasibility against real daily apps before any UI exists. |
| D7 | Model default | **Discover local models at launch (LM Studio + Ollama); qwen preferred, then gemma; switchable via the status-menu Model submenu** | Josh, 2026-07-03. No hardcoded model id as source of truth — if the configured model isn't served, adopt the best available; `claude -p` remains the fallback only when no local server answers. |
| D8 | Trigger default (amends D2) | **Double-click defines immediately — no pill in between.** Pill becomes opt-in (`usePill`, menu: "Ask First (pill)") | Josh, 2026-07-03, after first real use: the extra click is friction; the answer is cheap and disposable, so just show it. ⌥ still bypasses the pill when it's enabled. |

## Why D1 became Swift-only

The exported radio said Swift shell + Rust daemon, but the D5 note ("rewrite fresh,
don't have to stick with Rust, consider Swift-only, what's typical for native Mac
apps?") reopened it. The daemon split existed to protect v1's Rust transports/history/
keyring as-is; a fresh rewrite deletes that argument. Remaining facts all point to
Swift-only: this species of app (PopClip, Raycast, Rectangle) is single-process Swift;
`claude -p` = `Process`, Ollama/LM Studio = `URLSession` streaming, keys = Security
framework, markdown = `AttributedString`. The v1 lesson we keep is the *boundary*, not
the language: `TangentEngine` (models, providers, history — no AppKit imports) vs the
app layer (tap, AX, panels, status item). If a Rust core ever matters again, that seam
is where it slots in.

## Product notes from review (catchall)

- **First-run onboarding**: guided config flow on first open — permissions walk-through
  (Accessibility grant), provider setup (local LLM endpoint detected/configured once and
  persisted), trigger choices. Never re-ask for local LLM config.
- **Testing ground rules**: build and test continuously as we go. Tests must not steal
  focus or jerk the pointer around — prefer compile checks, self-reads, and one-shot
  probes of the frontmost app; anything interactive (real double-clicks) is handed to
  Josh to drive.
