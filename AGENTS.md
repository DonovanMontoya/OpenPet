# OpenPet Agent Guide

## Purpose

`OpenPet` is a standalone macOS desktop companion app for AI workflows.

The product goal is to make model and agent activity visible through a small desktop pet that reacts to real work instead of acting like a static mascot. The app should remain vendor-agnostic at the event layer so it can integrate with multiple AI tools without being tightly coupled to any one desktop client.

The current v1 target is:

- native macOS app built with `SwiftUI` plus narrow `AppKit` bridges
- floating overlay pet window
- minimal menu bar + settings surface
- deterministic behavior engine
- adapter-based integrations for `Codex CLI` and `LM Studio`

## Product Goals

- Show meaningful agent activity at a glance.
- Keep the pet lightweight, ambient, and always available.
- Support richer pet behavior than Codex’s baked-in pet.
- Normalize events from multiple AI tools into one shared runtime.
- Let future agents add new adapters and pets without rewriting the app shell.

## Non-Goals For V1

- No direct integration with Codex desktop app internals.
- No desktop UI automation for vendor apps.
- No cloud backend or account dependency.
- No attempt to let models directly control animation frames.
- No compatibility promise with Codex’s fixed `8x9` sprite atlas format.

## Current Architecture

### App shell

- [CompanionPetApp.swift](/Users/donovan/Documents/Github/OpenPet/Sources/CompanionPet/CompanionPetApp.swift) defines the SwiftUI app entry.
- [AppDelegate.swift](/Users/donovan/Documents/Github/OpenPet/Sources/CompanionPet/App/AppDelegate.swift) starts the accessory app and wires the overlay + status item.
- [OverlayWindowController.swift](/Users/donovan/Documents/Github/OpenPet/Sources/CompanionPet/App/OverlayWindowController.swift) owns the borderless floating pet window.
- [StatusBarController.swift](/Users/donovan/Documents/Github/OpenPet/Sources/CompanionPet/App/StatusBarController.swift) owns the menu bar UI.
- [SettingsView.swift](/Users/donovan/Documents/Github/OpenPet/Sources/CompanionPet/Views/SettingsView.swift) exposes configuration and test hooks.

### App state

- [AppModel.swift](/Users/donovan/Documents/Github/OpenPet/Sources/CompanionPet/App/AppModel.swift) is the main orchestration layer.
- It owns:
  - persisted settings
  - selected pet
  - current semantic state
  - adapter lifecycle
  - event consumption
  - overlay interaction behavior

### Event model

- [CompanionEvent.swift](/Users/donovan/Documents/Github/OpenPet/Sources/CompanionPet/Core/CompanionEvent.swift) defines the normalized internal event schema.
- All adapters must emit `CompanionEvent` values instead of directly mutating UI state.
- The app should stay event-driven. Avoid adding vendor-specific state directly to the overlay layer.

### Behavior engine

- [BehaviorEngine.swift](/Users/donovan/Documents/Github/OpenPet/Sources/CompanionPet/Core/BehaviorEngine.swift) maps normalized events into semantic pet states.
- It is deterministic and timer-driven.
- If you add new behaviors, update the behavior engine first, then update pet manifests and rendering.

### Pet runtime

- [PetManifest.swift](/Users/donovan/Documents/Github/OpenPet/Sources/CompanionPet/Core/PetManifest.swift) defines the pet asset contract.
- [PetLibrary.swift](/Users/donovan/Documents/Github/OpenPet/Sources/CompanionPet/Core/PetLibrary.swift) loads the built-in pet plus custom pets from Application Support.
- [OverlayPetView.swift](/Users/donovan/Documents/Github/OpenPet/Sources/CompanionPet/Views/OverlayPetView.swift) renders the active frame.

The current built-in pet is symbol-driven and stored at:

- [pet.json](/Users/donovan/Documents/Github/OpenPet/Sources/CompanionPet/Resources/DefaultPets/orbiter/pet.json)

### Integrations

- [CodexCLIAdapter.swift](/Users/donovan/Documents/Github/OpenPet/Sources/CompanionPet/Adapters/CodexCLIAdapter.swift)
  - launches `codex exec --json`
  - parses structured output
  - emits normalized events

- [CodexExecJSONParser.swift](/Users/donovan/Documents/Github/OpenPet/Sources/CompanionPet/Adapters/CodexExecJSONParser.swift)
  - translates Codex JSON event lines into `CompanionEvent`

- [LMStudioProxyAdapter.swift](/Users/donovan/Documents/Github/OpenPet/Sources/CompanionPet/Adapters/LMStudioProxyAdapter.swift)
  - runs a local OpenAI-compatible proxy
  - forwards requests to LM Studio
  - emits normalized lifecycle events around request/stream activity

- [SimpleHTTPServer.swift](/Users/donovan/Documents/Github/OpenPet/Sources/CompanionPet/Networking/SimpleHTTPServer.swift)
  - lightweight local HTTP server for the proxy path

## Semantic States

These are the current runtime states:

- `idle`
- `ambient`
- `thinking`
- `working`
- `replying`
- `success`
- `error`
- `waiting_for_user`
- `disconnected`
- `sleeping`

If you add a new state:

1. Add it to `CompanionStateName`
2. Update the behavior engine rules
3. Update pet manifests and fallback expectations
4. Add or update tests

Do not add a state only in rendering or only in a single adapter.

## Design Rules For Future Agents

- Keep the app vendor-agnostic at the runtime level.
- Put integration-specific logic inside adapters, not in `AppModel`.
- Prefer structured data or API-level integrations over scraping or automation.
- Keep the AppKit bridge narrow and explicit.
- Preserve deterministic behavior selection; do not let an LLM directly choose arbitrary animation frames.
- Extend manifests conservatively and preserve fallback to `idle`.
- Do not regress the app into a passive non-clickable overlay unless explicitly requested.

## Interaction Intent

The overlay pet should feel alive and useful:

- clickable
- directly draggable
- compact
- always on top of normal windows
- visually unobtrusive
- responsive to background AI activity

If interaction changes are made, verify both:

- normal pointer usage is ergonomic
- overlay behavior still feels ambient rather than like a regular app window

## Safe Extension Paths

Good next steps:

- richer click interactions
- better pet asset packs
- custom pet import flow
- more expressive animation states
- `Ollama` adapter
- `Claude` adapter if there is a stable API or CLI path
- adapter health diagnostics
- packaging into a proper `.app`

Higher-risk changes:

- desktop automation of vendor apps
- global input hooks
- opaque proprietary integrations
- putting vendor-specific assumptions into the shared behavior engine

## Build And Test

Use these from the repo root:

```bash
swift test
swift run CompanionPet
```

If the repo has been moved and SwiftPM caches were copied from another path, clear them:

```bash
rm -rf .build
swift run CompanionPet
```

## Testing Expectations

Before finishing meaningful changes, run `swift test`.

Current coverage includes:

- behavior engine transitions
- pet manifest validation/loading
- Codex exec JSON parsing
- overlay geometry helpers
- LM Studio proxy passthrough

If you change any of those subsystems, extend the corresponding tests under:

- [CompanionPetTests](/Users/donovan/Documents/Github/OpenPet/Tests/CompanionPetTests)

## Known V1 Constraints

- The app currently runs as a SwiftPM executable rather than a packaged app bundle.
- The built-in pet is simple and symbolic, not a polished sprite character.
- Codex integration depends on `codex exec --json` being available locally.
- LM Studio integration assumes an OpenAI-compatible local endpoint.

## Short Project Summary For New Threads

If you need to hand this repo to another agent, use this summary:

`OpenPet` is a macOS AI companion overlay app. It renders a floating clickable/draggable pet, maps normalized AI activity events into semantic states, and currently integrates with Codex CLI and LM Studio. The main architecture is `AppModel` + `BehaviorEngine` + manifest-driven pet runtime + adapter layer. Keep integrations isolated, keep runtime logic vendor-agnostic, and verify changes with `swift test`.
