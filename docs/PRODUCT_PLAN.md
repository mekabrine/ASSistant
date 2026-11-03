# ASSistant product and architecture plan

Status: **design only**, 2026-11-03. Target: iPhone/iPad running iOS **16.0+**. This document is not a claim that features are implemented.

## Product

Native SwiftUI AI assistant; no provider lock-in. A conversation can become a persistent task, an approved native tool action, or a reusable HTMLApp mini app.

Navigation: **Chat**, **Agents**, **Tasks**, **Apps**, **Settings**, with a global quick-action palette and a dedicated **Memory** area accessible from Chat/Settings.

## Feature inventory and release priorities

### P0: reliable foundation
- SwiftUI adaptive interface, dark/light mode, accessibility and iPad layout.
- Chats: new, rename, folders, archive, search, delete, export/import, markdown/code blocks, edit/regenerate/branch, attachments, stop streaming; model and token/cost badges.
- Configurable API profiles: display name, URL, protocol adapter, auth mode (Bearer, API key/custom header, no auth), model ID, optional model discovery, headers (excluding dangerous overrides), per-model capabilities, max output tokens, temperature and reasoning settings when supported.
- Adapters: OpenAI-compatible streaming first; native Anthropic/Gemini and Ollama/LM Studio later. URL alone cannot ensure compatibility.
- Credentials in Keychain; never CloudKit-sync raw keys or publish them in app bundles, mini apps, logs, or crash reports. Provide manual credentials setup on additional devices.
- Core Data + NSPersistentCloudKitContainer for local-first persistence and sync; explicit sync status, offline support, account changes, repair/export controls. Decide per-entity privacy/storage boundaries up front.
- Full message history persists locally; **only selected context** goes to LLM.
- Unit and UI tests, crash-safe migrations, storage backups.

### P1: context and durable memory
- Memory scopes: user-global, per-agent, per-project, per-conversation, per-generated-mini-app.
- Memory types: preferences, stable facts, people/entities, goals, projects, decisions, tasks, procedures/skills, timelines, contradictions, ephemeral context, user-pinned instructions.
- Each memory: id, normalized content, type, scope, owner, source message IDs, confidence, created/updated/last-used, TTL/expiration, importance, sensitivity, sync state, supersededBy, user-pinned flag.
- Memory controls: inspect/edit/pin/delete; disable auto-extraction by scope; inspect **why this was remembered**; export and forget.
- Summarize in batches only when needed, not each turn; use the user's configured inexpensive model or on-device heuristics. Preserve original messages; summaries are cache layers.
- Select evidence using lexical search first (SQLite FTS5), optional embedding search if provider available, recency + relevance + importance reranking, source trace and deduplication.
- Pinned facts are not blindly appended in every call; prioritize relevant pinned facts subject to a bounded core profile.
- Multi-turn references retrieve relevant chat excerpts by ID; resolve contradictions and outdated facts without quietly overriding user edits.
- Show context inspector: budget, injected sources, estimated tokens and pricing.

### P2: action system, permissions and HTMLApp
- Native tool registry: calendars, reminders, contacts, camera/photos, microphone/speech, files, location, notifications, clipboard, web/search, Share Sheet, Shortcuts/App Intents, GitHub, custom HTTPS requests, MCP tools where feasible.
- Tools have typed schemas, timeouts, cancellation, capability flags, audit logs, per-action approval policy, sensitivity classes and limited scopes.
- The app can **request** supported system permissions when needed; it cannot grant itself permissions, bypass entitlements, or have arbitrary unrestricted access. Permissions are off by default and granted just-in-time; user can revoke.
- Read-only tools can be allowed per scope; sending messages, publishing apps/code, modifying contacts/files, buying, deleting, or sharing data should require a clear confirmation.
- HTMLApp integration (required direct flow): load the existing HTMLApp **skill file** and any referenced guidance for app generation; generate **one self-contained HTML file** with embedded CSS and JS; validate/preview it; upload the raw .html to a reachable HTTPS URL using an approved publishing service; transform the resulting URL into the **existing HTMLApp install URL scheme**; open that URL on the device; let HTMLApp handle its existing import/install confirmation. Keep hosted source URL and version locally for future edits. Do not require a JSON manifest, a new installation service in HTMLApp, or a custom app package format.
- Follow the existing HTMLApp bridge contract from `HTMLAppV3/HTMLAppBridgeRegistry.swift`, including native permission gating and secure storage. Do not assume arbitrary cross-app remote execution.
- Allow versioned *agent actions* for installed mini apps only through explicit user-authorized host APIs; don't expose Keychain/provider tokens to mini-app JavaScript.
- HTMLApp owns native app runtime and its existing URL-scheme install handler; ASSistant owns skill-driven generation, validations, publishing, and opening the install link. Verify the exact existing scheme and the location/version of the HTMLApp skill file in the HTMLApp repository before coding this integration.

### P3: autonomous capabilities
- Agent profiles, custom instructions, specialized tools, tool/model routing, per-agent memory, shared project context.
- Durable task execution with states queued/running/needsApproval/paused/completed/failed/cancelled; full provenance and resumability.
- Scheduling requires appropriate notification/background/cloud-worker design. iOS background execution is limited; promises of continuous local autonomy are not viable.
- Cloud browser/code execution via optional isolated infrastructure, never unrestricted remote commands on iOS.
- Subagents and skill marketplace only after stable permission and memory systems.
- Voice, Siri Shortcuts, widgets, Live Activities as progressive features subject to OS availability.

## Context engine — inspired by attached Nexus AI Story Engine

The supplied Story Engine code has a five-tier context builder:
1. selected character/system profile,
2. global/pinned facts,
3. session abstract and categorized facts,
4. recalled abstracts from other sessions using keyword matching,
5. token-budgeted recent-message window.

It also asynchronously summarizes older messages and extracts durable facts, using rough length/4 token estimation and a configurable message window. Preserve this principle, but improve memory storage, deduplication, retrieval, and accounting; keep original chat history, do not routinely send it.

### Context assembly, per query

1. Determine task/intent and agent permissions locally where possible.
2. Reserve output + safety margin and fixed required system/tool schema budget.
3. Assemble minimal immutable instructions and a bounded user profile.
4. Query memories scoped to the current agent/project/session; merge prioritized relevant global memories.
5. Fetch relevant snippets of earlier messages and cross-chat summaries using FTS; embeddings optional.
6. Include the latest full turns as a sliding window, preserving tool call/result pairs and user turns. Keep current user input intact.
7. Strip irrelevant/expired/superseded facts, deduplicate near duplicates, avoid injecting private memory into unauthorized tools or providers.
8. Fit to model's actual available context; use tokenizer-specific counts where feasible, conservative estimation otherwise.
9. Display a diagnostic record of what was injected, token estimates and reason, excluding sensitive content from telemetry.
10. Persist exact prompt provenance and model usage **locally**, with optional opt-in diagnostic export.

Suggested default budget allocation **within available input budget**: instructions/tool schemas 15%, profile and task state 10%, relevant facts 15%, retrieved evidence 20%, recent chat 35%, margin 5%. All values adjustable and reallocatable based on task, not rigid quotas. A user can select a hard maximum-context cap, e.g. 4k/8k/16k/auto.

### Extraction and compaction

- New turns are immediately stored as immutable messages.
- Extract candidate memories when a conversation reaches a meaningful boundary or enough uncategorized content accumulates, instead of paying for another model call after every response.
- Summaries are rolling, hierarchical, versioned and reference source message ranges.
- Candidate memories are staged, normalized and deduplicated; sensitivity/classification occurs prior to committing them. Do not store hidden chain-of-thought or sensitive inferred traits.
- Facts can conflict: represent alternatives with provenance and ask or qualify rather than silently preferring one.
- User-edited or pinned memories override model guesses.
- Make deletions propagate through local indexes, summary derivatives and synced tombstones. CloudKit convergence and deletion semantics require tests.

### Example memory record

```json
{
  "id": "uuid",
  "scope": "project:htmlapp",
  "kind": "decision",
  "text": "Build generated HTML apps as versioned, reviewable packages",
  "sourceMessageIDs": ["..."],
  "confidence": 0.98,
  "importance": 0.9,
  "pinned": false,
  "createdAt": "...",
  "updatedAt": "...",
  "expiresAt": null,
  "supersededBy": null
}
```

## Sync and privacy

Architecture: Core Data persistent store mirrored via `NSPersistentCloudKitContainer`. iOS 16 support is required; **do not depend on SwiftData** (introduced later). Entities include Conversation, Message, MessageRevision, AttachmentMetadata, Agent, MemoryItem, MemorySource, SessionSummary, Task, ToolAudit, MiniAppReference, ProviderProfileMetadata and SyncTombstone.

CloudKit private database is appropriate for a user's own data. Local attachments can be stored as files with explicit CKAsset support, upload limits and local cache cleanup; do not put multi-megabyte attachment blobs into message records. Handle multiple devices editing a chat, unique IDs, deterministic sort, sync duplicates and concurrent deletes.

User API secrets stay Keychain-local and are not in CloudKit records. Provider names/model selections may sync. For cross-device key sharing, a future explicit encrypted sync design would be required; do not silently attempt to copy Keychain keys through the app's database.

CloudKit requires a configured container, entitlements, valid provisioning profile and signature on-device. It should degrade gracefully if the environment lacks iCloud capability. Explain sync status rather than falsely claiming success. Use a signed test build to test real CloudKit; an unsigned IPA cannot validate CloudKit execution.

Security: sensitive memories (health, finances, exact location, intimate or identity information) require explicit collection/review settings; memory should not infer/store sensitive categories by default. Provider requests disclose what data is sent.

## iOS permission matrix

Each tool declares: Info.plist usage string, required entitlement if any, supported iOS API, current authorization lookup, requested scope, OS prompt behavior, audit event and revocation help.

- Camera: AVCaptureDevice/camera permission.
- Photos: Photos picker where possible; full library access separately and only if needed.
- Microphone/speech: request mic and speech recognition independently when applicable.
- Calendar/reminders: EventKit scoped to iOS 16 authorization semantics; conditionally support newer APIs on newer OS versions.
- Contacts: Contacts framework authorization.
- Location: When In Use first; background only with clear use case, required entitlements and review.
- Notifications: UNUserNotificationCenter authorization.
- Bluetooth, motion, health, NFC, etc.: only if a real feature needs them and required capabilities exist; feature detection.
- Files: user-selected document picker / security-scoped URLs.
- Clipboard: prefer user-initiated paste.
- No blanket device-control, SMS/phone-call, universal app data or bypassed privacy permissions.

## GitHub Actions / unsigned IPA contract

Only trigger:

```yaml
on:
  workflow_dispatch:
    inputs:
      configuration:
        type: choice
        options: [Release, Debug]
        default: Release
```

No push, pull_request, schedule, workflow_run or release auto-build trigger. No hidden dependency workflow that consumes runners unexpectedly.

Once XcodeGen project exists, the manual macOS runner will:
1. Checkout commit, install pinned XcodeGen, generate Xcode project.
2. `xcodebuild -project ASSistant.xcodeproj -scheme ASSistant -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build`.
3. Verify actual device architecture, iOS minimum, bundle ID, executable and embedded Info.plist; include static entitlements metadata only if appropriate, without claiming those entitlements are active.
4. Place `ASSistant.app` under `Payload/` and ZIP as `ASSistant-unsigned.ipa`.
5. Upload IPA and build logs as artifacts with short retention. Never publish provider keys or provisioning secrets in logs.
6. Do not use `xcodebuild -exportArchive` with no signing and claim it is a distributable signed IPA.
7. Document post-build signing/installation step separately. Stock iOS requires valid signing; provisioning for CloudKit is more restrictive than code-only sideload testing.

Build failure is the correct outcome if Xcode project/schema is missing; create workflow together with the compilable project to avoid intentionally failing manual runs.

## Technical decisions

- UI: SwiftUI native; WKWebView only for HTMLApp preview or rich app-specific content.
- Persistence: Core Data + CloudKit, SQLite FTS index local for retrieval; migrations/versioning tested from day one.
- Requests: URLSession; SSE parser; cancellable tasks; adapter protocol.
- Security: Keychain storage, ATS HTTPS by default, localhost only for intentional local-mode adapters; cloud execution never arbitrarily fetches internal addresses.
- Background: BGTaskScheduler best-effort refresh; cloud workers only as an opt-in service.
- Build: XcodeGen `project.yml`, fixed deployment target 16.0, workflow_dispatch only.
- Tests: memory relevance and token caps, prompt injection isolation, agent authorization, sync merge/offline replays, API adapters, HTMLApp manifest/migration/rollback, iOS 16 API availability, unsigned package structure.

## Milestones / acceptance

**M0** Initialize app, XcodeGen, baseline SwiftUI tabs and manual unsigned IPA workflow. Acceptance: manually started GitHub Action generates a valid structurally unsigned IPA artifact; app targets iOS 16; no automatic runs.

**M1** BYO API chat + persistence. Acceptance: configure arbitrary OpenAI-compatible URL/model/key; stream response; restart with chat history; keys never in logs or CloudKit.

**M2** Cloud sync and Memory v1. Acceptance: chats and curated memories sync bidirectionally between *signed, properly provisioned* devices; offline edits converge; model receives capped relevant context instead of entire transcript.

**M3** Agents, tools, approvals. Acceptance: a permission is requested only when needed; tool calls cannot bypass denial; audit view shows provenance; no unauthorized destructive actions.

**M4** HTMLApp app generator. Acceptance: follow the HTMLApp skill to produce a single file, preview/validate, host at HTTPS URL, open HTMLApp's existing install URL scheme, confirm user can install in HTMLApp; future edits preserve user data.

**M5** Scheduling, background service, extra adapters, advanced skills, optimization.

## Open verification items

- Read the actual HTMLApp skill file and identify the existing URL scheme and its exact required URL encoding; use those unchanged. No new install endpoint planned.
- Select bundle ID and CloudKit container ID for signed testing. Do not assume arbitrary sideload signing supports CloudKit.
- Decide whether private provider URL/config metadata can sync and what encryption boundaries are acceptable.
- Verify Swift/iOS SDK availability on selected GitHub-hosted macOS runner before pinning versions.
