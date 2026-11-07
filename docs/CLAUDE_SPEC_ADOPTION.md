# Claude build spec adoption and startup reliability

Source of priorities: the user-provided **BYO-API AI Agent App for iOS: Full Build Spec** dated 2026-11-07. Its design is the primary product guide going forward, except where it conflicts with explicit user requirements (iOS **16.0 minimum**, **iCloud syncing between devices**, existing **HTMLApp import URL**, **manual-only GitHub Actions**).

## Priority 0: launch reliability before new features

The original prototype passed a GitHub Actions unsigned device build on 2026-11-03, but that did **not** verify runtime launch. A user reports immediate launch termination.

Potential issues discovered in source and fixed in the code:
- The first app launch attempted CloudKit immediately even with unsupported unsigned/sideload signing. The new default is local SQLite-backed Core Data and opt-in CloudKit; signed iCloud sync can be enabled in Settings.
- On persistent-store failure, the old code attempted to call `loadPersistentStores` again on the **same container**. The new implementation uses a *fresh local NSPersistentContainer* and the same on-disk SQLite store, without clearing user data.
- The old generic model used an attribute named `deleted`, which conflicts with NSManagedObject's deletion state/KVC. It now uses `tombstoneFlag` with a Core Data renaming identifier for the old field.
- An interrupted database startup sets persistent recovery mode so the next launch bypasses CloudKit. The Settings screen can explicitly retry iCloud after restarting.

These changes are **source-level fixes, not a confirmed crash diagnosis**. An iOS crash report/backtrace is still needed if a launch crash remains. Never tell the user a build is fixed without an iPhone/simulator test.

**Regression gate:** Create in-memory Core Data model + set/retrieve tombstone, launch under iOS 16, and test both unsignable local and properly provisioned CloudKit configurations. No automatic paid CI workflows.

## Primary product decisions adapted from Claude

1. **Local-first / no forced backend:** Users bring any supported model endpoint; API keys remain in Keychain. Never require an ASSistant account. Hosting is optional until the user wants a publicly imported HTMLApp.
2. **Provider abstraction:** Move monolithic `LLMService` toward `ChatProvider` protocol with streamed deltas, model discovery, capability flags and fallback. Implement OpenAI Chat Completions, Responses API, Anthropic Messages, Gemini and Ollama; custom model names always permitted.
3. **Whisper first:** Cloud BYO Whisper endpoint should be the default broadly compatible transcription option, with on-device Whisper and optional Apple Speech fallback. Current prototype has **Apple Speech only** and does NOT yet satisfy this.
4. **Real agent loop:** Explicit plan → tool call(s) → observe → continue, bounded by max steps. Tool tiers and visible audit timeline. Current prototype supports only single JSON proposals and confirmations.
5. **Tool breadth:** Pluggable web search/fetch, sandboxed JS, local file operations, Apple data, optional remote MCP, optional user-hosted remote runner, image generation endpoints and Shortcuts. No unrestricted iOS background execution.
6. **Conversation UX:** Better markdown/code, branching, projects, file retrieval, images, reasoning visibility, per-model budget and privacy controls.
7. **Device UI:** Native iOS 16+ SwiftUI with conditional modern materials; Liquid Glass on new SDKs with availability checks, VoiceOver/Dynamic Type, widget/Live Activity support where available.
8. **Data/storage:** Claude recommends SQLite via GRDB. The existing prototype already uses Core Data + CloudKit mirroring to satisfy the user's iCloud sync requirement. **Do not replace it in place or destroy saved data.** Before moving to GRDB, implement explicit migration + a separately proven bidirectional CloudKit sync engine. Continue using Core Data as the safer transitional path.
9. **Privacy:** End-to-end encrypted iCloud sync is **not implemented**; the current private CloudKit database alone is not a claim of app-level E2E encryption. Sensitive memories require proper classification, controls and retention. No analytics by default.
10. **Sideloading:** Manual unsigned IPA is an artifact only. Normal iPhone installation and CloudKit need appropriately signed entitlements. Never fire workflows without explicit user request.

## HTMLApp integration — verified against source, not guesses

- Skill: `mekabrine/htmlapp/HTMLApp/Resources/HTMLApp-AI-App-Builder-SKILL.md`.
- Existing iOS URL import handler: `mekabrine/htmlapp/HTMLAppV3/RemoteHTMLImport.swift`:
  `htmlapp://import?url=<URL-encoded PUBLIC HTTPS HTML file URL>`.
- Restricts public HTTPS; the current HTMLApp importer limits remote HTML to **12 MB**, checks UTF-8 document syntax and rejects private/local addresses or unsafe redirects.
- HTMLApp opens an **uncommitted draft**. The user explicitly saves the imported app inside HTMLApp.
- ASSistant should generate complete **single-file HTML with embedded CSS/JS**, preview and validate, request approval, upload to Gist/user server or use private share-sheet import, then open the exact verified URL.
- The mini-app host's native bridge stays within HTMLApp. Do not invent an app manifest or duplicate HTMLApp's runtime.

## Target release sequencing

- **R0:** Restore reliable launch on unsigned/sideload test device and iOS 16 simulator. No feature expansion until verified.
- **R1:** BYO API chat + local storage + source-level tests + manual unsigned IPA.
- **R2:** Cloud Whisper (including microphone permission/recording + transcription), provider fallback and robust streaming.
- **R3:** True bounded agent execution loop and permission tiers; useful web/file/device tools.
- **R4:** CloudKit device sync with correct entitlement provisioning and conflict resolution; verify memory search and token savings.
- **R5:** HTMLApp publish/install/edit polish, private handoff, safe preview and versioned recovery.
- **R6:** Advanced providers, remote MCP/runner, image models, widgets, Shortcuts, user experience.

## Verification before claiming completion

- Capture an iPhone crash log with exception type and first app-owned frames (iOS Settings → Privacy & Security → Analytics & Improvements → Analytics Data, or Xcode Devices and Simulators).
- Run tests for model/store startup; check old-store migration and CloudKit recovery path.
- Have user manually run GitHub Actions only when ready; ensure the workflow still has exclusively `workflow_dispatch`.
- Confirm signed test app launch on real iOS 16+ and prove iCloud updates across two appropriately provisioned devices.
