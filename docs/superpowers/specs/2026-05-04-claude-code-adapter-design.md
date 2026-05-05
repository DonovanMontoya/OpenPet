# Claude Code Adapter — Design Spec

**Date:** 2026-05-04
**Status:** Approved

---

## Summary

Add a `ClaudeCodeAdapter` to OpenPet so the companion pet reacts to real Claude Code activity. The adapter has two observation paths — file polling (passive, zero config) and hook-based HTTP events (real-time, auto-configured) — plus a menu item to launch Claude Code in Terminal.app.

---

## Architecture

### New files

| File | Purpose |
|---|---|
| `Sources/CompanionPet/Adapters/ClaudeCodeAdapter.swift` | Top-level `CompanionAdapter`. Coordinates poller and hook receiver. Exposes `openTerminalSession()`. |
| `Sources/CompanionPet/Adapters/ClaudeCodeSessionPoller.swift` | Actor that polls `~/.claude/projects/**/*.jsonl` every 1 second, tracking per-file byte offsets via `SessionCursor`. |
| `Sources/CompanionPet/Adapters/ClaudeCodeHookReceiver.swift` | Wraps `SimpleHTTPServer` on the configured port (default 5051). Merges hook entries into `~/.claude/settings.json` on start; removes them on stop. |
| `Sources/CompanionPet/Adapters/ClaudeCodeJSONLParser.swift` | Stateful struct. Parses Claude Code JSONL session lines into `[CompanionEvent]`. |
| `Sources/CompanionPet/Adapters/ClaudeCodeHookParser.swift` | Stateless struct. Converts hook HTTP POST payloads into `[CompanionEvent]`. |

### Modified files

| File | Change |
|---|---|
| `Sources/CompanionPet/Core/SettingsStore.swift` | Add `ClaudeCodeAdapterSettings`. Add `claudeCode` field to `CompanionSettings`. |
| `Sources/CompanionPet/App/AppModel.swift` | Add `claudeCodeAdapter` var. Update `rebuildAdapters()`, `handleSettingsChange(from:)`, `sourceLabel(for:)`. Add `launchClaudeCode()`, `autoDetectClaude()`, and settings update helpers. |
| `Sources/CompanionPet/App/StatusBarController.swift` | Add `claudeCodeStatusItem` and `launchClaudeCodeItem`. Wire into `configure()` and `refresh()`. |

---

## Settings

```swift
struct ClaudeCodeAdapterSettings: Codable, Equatable, Sendable {
    var enabled: Bool = true
    var executablePath: String = "/usr/local/bin/claude"
    var workingDirectoryPath: String = NSHomeDirectory()
    var hookListenerPort: Int = 5051
    var autoConfigureHooks: Bool = true
    var displayName: String = "Claude Code"
}
```

`CompanionSettings` gains:
```swift
var claudeCode: ClaudeCodeAdapterSettings = .init()
```

`handleSettingsChange(from:)` triggers `rebuildAdapters()` when `claudeCode` changes, matching the existing Codex and LM Studio pattern.

---

## ClaudeCodeJSONLParser — Event Mapping

Claude Code writes sessions to `~/.claude/projects/<url-encoded-path>/<session-uuid>.jsonl`. Each line is a JSON object with a `type` field (`"user"`, `"assistant"`, `"summary"`).

| Condition | Events emitted |
|---|---|
| First `user` line in file | `sessionStarted` + `thinkingStarted` (with prompt text) |
| Subsequent `user` line with text content | `thinkingStarted` |
| `user` line with `tool_result` content | `toolFinished` per result |
| `assistant` line, `stop_reason: "tool_use"` | `toolStarted` per `tool_use` content block |
| `assistant` line, `stop_reason: "end_turn"` | `streamStarted` + `streamDelta` (text) + `streamFinished` + `sessionEnded` |
| `assistant` line, other `stop_reason` | `sessionEnded` |
| `summary` line | ignored |

Parser tracks `seenFirst: Bool`, `sessionID: String?`, `streamOpen: Bool`, and `activeTools: Set<String>` across calls (same pattern as `CodexSessionJSONLParser`).

---

## ClaudeCodeHookParser — Event Mapping

Hooks fire in real time. The parser converts raw hook JSON payloads into `CompanionEvent` values.

| Hook event | Events emitted |
|---|---|
| `PreToolUse` | `thinkingStarted` + `toolStarted` (tool name; `command` payload from input if available) |
| `PostToolUse` — no error | `toolFinished` |
| `PostToolUse` — with error | `toolFinished` + `error` |
| `Stop` | `streamFinished` + `sessionEnded` |
| `Notification` with `notification_type: "waiting_for_input"` | `userWaiting` |
| Other `Notification` | ignored |
| `SubagentStop` | `sessionEnded` |

---

## ClaudeCodeHookReceiver — Hook Auto-Configuration

On `start()`:
1. Read `~/.claude/settings.json` (create as `{}` if absent).
2. For each of `PreToolUse`, `PostToolUse`, `Stop`, `Notification`: append an entry to the hook list if one with `/openpet/hook` in the command does not already exist.
3. Save the file.
4. Start `SimpleHTTPServer` on `settings.hookListenerPort`.

Hook command format:
```
/usr/bin/curl -s -X POST http://127.0.0.1:{PORT}/openpet/hook -H 'Content-Type: application/json' -d @-
```

HTTP handler: `POST /openpet/hook` — reads JSON body, calls `ClaudeCodeHookParser`, sends resulting events to the adapter's `EventChannel`.

On `stop()`:
1. Stop `SimpleHTTPServer`.
2. Read `~/.claude/settings.json`, remove all hook entries whose `command` contains `/openpet/hook`, save file.

Existing user-defined hooks are never removed. The `/openpet/hook` path in the command URL is the identification marker.

---

## ClaudeCodeSessionPoller

Actor with the same structure as `watchCodexSessions()` in `CodexCLIAdapter`:

- Polls `~/.claude/projects/` (and nested subdirectories) every 1 second via `FileManager`.
- Identifies `.jsonl` files, picks the most recently modified.
- Tracks byte offset per file via `SessionCursor` (same struct shape as the Codex adapter).
- Feeds new lines to `ClaudeCodeJSONLParser`, forwards events to the adapter's `EventChannel`.

---

## ClaudeCodeAdapter

Conforms to `CompanionAdapter` with `id = "claude-code"`, `capabilities = [.launchesSessions, .healthChecks]`.

**`start()`**
1. Verify executable at `settings.executablePath` (emits `adapterDisconnected` if missing, same as Codex).
2. Set health to `.connected`, emit `adapterConnected`.
3. Start `ClaudeCodeSessionPoller` as a background `Task`.
4. Start `ClaudeCodeHookReceiver` (if `autoConfigureHooks` is true).

**`stop()`**
1. Cancel poller task.
2. Stop hook receiver (cleans up `settings.json`).
3. Set health to `.disconnected`.
4. Finish `EventChannel`.

**`openTerminalSession(workingDirectory: URL?)`**
Uses `NSAppleScript` to open Terminal.app:
```applescript
tell application "Terminal"
    activate
    do script "cd '/path/to/dir' && /usr/local/bin/claude"
end tell
```
Working directory defaults to `settings.workingDirectoryPath` if the caller passes `nil`.

---

## Menu Changes

### StatusBarController

New items added in `configure()`:
- `claudeCodeStatusItem` — non-clickable, shows `"Claude Code: {health}"` (same pattern as `codexStatusItem`)
- `launchClaudeCodeItem` — `"Launch Claude Code"`, calls `appModel.launchClaudeCode()`; disabled when adapter health is not `.connected`

Menu order:
```
State: …
---
Codex: …
LM Studio: …
Claude Code: …
---
Launch Claude Code          ← new; disabled when disconnected
---
Lock Overlay
Pause Animations
Size >
Pet >
---
Open Settings…
Quit
```

### AppModel

- `launchClaudeCode()` — calls `claudeCodeAdapter?.openTerminalSession(workingDirectory: URL(filePath: settings.claudeCode.workingDirectoryPath))`
- `autoDetectClaude()` — checks common install paths (`/usr/local/bin/claude`, `/opt/homebrew/bin/claude`) then falls back to `which claude`, mirrors `autoDetectCodex()`
- Settings update helpers: `setClaudeCodeEnabled(_:)`, `updateClaudeCodeExecutablePath(_:)`, `updateClaudeCodeWorkingDirectory(_:)`, `updateClaudeCodePort(_:)`
- `sourceLabel(for:)` gains `case "claude-code": return "Claude Code"`

---

## Data Flow

```
~/.claude/projects/**/*.jsonl
        │ (poll every 1s)
ClaudeCodeSessionPoller
        │
        ▼
ClaudeCodeJSONLParser → [CompanionEvent]
        │
        ▼
EventChannel<CompanionEvent>
        ▲
ClaudeCodeHookParser → [CompanionEvent]
        ▲
ClaudeCodeHookReceiver (POST /openpet/hook)
        ▲
Claude Code hooks → /usr/bin/curl POST
```

Both paths feed the same `EventChannel`. `ClaudeCodeAdapter` forwards it to `AdapterHost`, which fans out to `AppModel` → `BehaviorEngine`.

---

## Testing

New test coverage to add under `Tests/CompanionPetTests/`:

- `ClaudeCodeJSONLParserTests` — covers: first user line → sessionStarted + thinkingStarted; tool_use → toolStarted; tool_result → toolFinished; end_turn → streamStarted + streamDelta + streamFinished + sessionEnded; summary line → no events
- `ClaudeCodeHookParserTests` — covers: PreToolUse, PostToolUse (ok + error), Stop, Notification (waiting + other), SubagentStop
- `ClaudeCodeHookReceiverTests` — covers: settings.json hook merge (idempotent), hook removal leaves other hooks intact

No UI automation tests; verify menu item and terminal launch manually.

---

## Deduplication

When both the poller and hook receiver are active, it is possible for the same logical event to arrive twice — once in real time via a hook and once when the JSONL file line is read on the next poll tick. The `BehaviorEngine` is already idempotent for repeated events (repeated `toolStarted` does not change state), so duplicate events are tolerated without special handling in this iteration. If it causes visible flicker it can be addressed with a short-lived session-scoped dedup set in a follow-up.

---

## Out of Scope (this iteration)

- Settings UI for Claude Code (configurable via `SettingsView` in a follow-up)
- Session history browser
- Model selection for launched sessions
- Proxy path (Claude Code does not expose an OpenAI-compatible endpoint)
