# OpenPet

OpenPet is a native macOS desktop companion for AI workflows. Its goal is to recreate the feel of the Codex Pets feature, but as an agent-agnostic layer that can work across tools like Codex, Codex CLI, Claude Code, OpenCode, LM Studio, and future adapters instead of being tied to a single vendor experience.

The repo's Swift package product is named `CompanionPet`, but the project itself is `OpenPet`.

## Goal

OpenPet is trying to make the Codex Pets idea portable.

- Keep the delightful ambient desktop pet experience
- Preserve the idea that the pet reacts to real agent activity, not random idle animation alone
- Decouple the runtime from any one client so the same companion can follow work happening in different agent tools
- Normalize activity from multiple sources into one shared behavior engine and pet runtime

## What It Does

- Recreates the Codex Pets style of ambient activity feedback in a standalone macOS app
- Shows normalized AI activity through a lightweight always-on-top overlay pet
- Maps tool and session events into deterministic semantic states like `thinking`, `working`, `replying`, `success`, and `error`
- Exposes a menu bar control surface plus a settings window for configuration
- Supports built-in, custom, and Codex-format pet packs
- Stays vendor-agnostic at the runtime layer by translating adapter-specific activity into shared `CompanionEvent` values

## Current Integrations

The long-term direction is broad agent support. The current codebase includes adapters for:

- `Codex CLI`
  Watches local Codex session JSONL files, parses `codex exec --json` output, and can launch sample Codex sessions.
- `Claude Code`
  Watches local Claude Code session activity and can optionally auto-configure local hooks for faster updates.
- `OpenCode`
  Reads the latest exported local OpenCode session transcript and can launch an OpenCode terminal session.
- `LM Studio`
  Runs a small local OpenAI-compatible proxy and emits lifecycle events around requests and streaming responses.

## Architecture

The app is organized around a few narrow layers:

- `Sources/CompanionPet/App/AppModel.swift`
  Main orchestration layer for settings, pet selection, adapters, overlay behavior, and event consumption.
- `Sources/CompanionPet/Core/BehaviorEngine.swift`
  Deterministic state engine that translates normalized events into semantic pet states.
- `Sources/CompanionPet/Core/CompanionEvent.swift`
  Shared event schema and adapter contracts.
- `Sources/CompanionPet/Core/PetManifest.swift`
  Manifest-driven pet runtime for built-in and imported pets.
- `Sources/CompanionPet/Views/OverlayPetView.swift`
  SwiftUI overlay rendering for the pet and speech bubbles.
- `Sources/CompanionPet/App/OverlayWindowController.swift`
  Borderless floating window bridge for the overlay.
- `Sources/CompanionPet/Adapters/`
  Integration-specific adapters and parsers.

The app is event-driven by design. Adapters emit `CompanionEvent` values, and the behavior engine decides the pet state from there.

## Requirements

- macOS 14+
- Swift 6 toolchain
- Optional local tools depending on which adapters you enable:
  `codex`, `claude`, `opencode`, `LM Studio`

## Running The App

From the repo root:

```bash
swift run CompanionPet
```

Run tests with:

```bash
swift test
```

Build the signed app from Xcode with:

```bash
xcodegen generate
open OpenPet.xcodeproj
```

Use the `OpenPet` scheme. The project is generated from `project.yml`; update that file first, then rerun `xcodegen generate` when Xcode project settings need to change. Xcode signing is set to automatic with bundle identifier `io.openpet.OpenPet`, so select your development team in Xcode before archiving or using a non-ad-hoc signature.

If SwiftPM caches were copied from another path and the build behaves strangely:

```bash
rm -rf .build
swift run CompanionPet
```

## Packaging

The app currently runs well from `swift run`, but the repo now includes a first packaging pass for building a real macOS app bundle:

```bash
./scripts/package-macos-app.sh
```

That script will:

- build the Swift package in `release` mode
- create `dist/OpenPet.app`
- copy the `CompanionPet` executable into the app bundle
- wrap the SwiftPM resource files into a loadable `CompanionPet_CompanionPet.bundle`
- sign the executable, resource bundle, and app bundle

Useful environment overrides:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/package-macos-app.sh
VERSION="0.1.0" BUILD_NUMBER="1" ./scripts/package-macos-app.sh
SKIP_BUILD=1 ./scripts/package-macos-app.sh
```

The packaged app uses `LSUIElement`, so it behaves like an accessory/menu bar app rather than a normal Dock app.

## Using OpenPet

When the app launches, it runs as a macOS accessory app with:

- a floating overlay pet window
- a menu bar item
- a settings window

In Settings you can:

- pause animations
- lock overlay dragging
- reduce motion
- toggle speech bubbles
- change overlay size
- switch pets
- configure adapter executable paths and working directories
- launch Claude Code or OpenCode from the app
- run a sample Codex session

## Pet Packs

OpenPet supports:

- the built-in `Orbiter` pet
- custom pets stored in `~/Library/Application Support/CompanionPet/Pets`
- Codex pet folders stored in `~/.codex/pets`

Each pet pack is manifest-driven through a `pet.json` file. The built-in example lives at:

- `Sources/CompanionPet/Resources/DefaultPets/orbiter/pet.json`

States currently supported by the runtime include:

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
- `jumping`
- `waving`

## Project Layout

```text
Sources/CompanionPet/
  App/           App lifecycle, menu bar, windows, orchestration
  Adapters/      Codex, Claude Code, OpenCode, LM Studio integrations
  Core/          Events, behavior engine, settings, pet runtime
  Networking/    Lightweight HTTP server and request/response types
  Resources/     Built-in pet assets and manifests
  Views/         SwiftUI overlay and settings views

Tests/CompanionPetTests/
  Behavior engine, parsers, pet loading, proxy, and geometry tests
```

## Development Notes

- Keep runtime logic vendor-agnostic; integration-specific assumptions belong in adapters.
- Extend the behavior engine before adding new render-only states.
- Preserve deterministic state selection rather than letting adapters drive visuals directly.
- Run `swift test` before finishing meaningful changes.

## Status

OpenPet is currently a SwiftPM macOS app target rather than a packaged `.app` bundle, but the core overlay, adapter, and pet systems are already in place.
