# ASSistant — iOS 16+ BYO-API agent prototype

Native SwiftUI assistant integrating user-configured AI APIs, private local-first data, CloudKit synchronization, contextual memory, native device tools and [HTMLApp](https://github.com/mekabrine/htmlapp) installation.

**Status: source-code prototype; a manually triggered GitHub Actions build on Nov 3 succeeded, but the user's installed app reportedly crashes immediately on launch. Startup fixes committed Nov 7 are NOT yet device-verified.** A successful install, permission flow, iCloud synchronization or IPA build must not be assumed until device tests pass.


## November 7 feature expansion (source code, not device-verified)

- **Agent-controlled browser:** Explicit internet/shopping requests trigger real WKWebView web searches (with a Bing fallback), bounded read-only page observations, link follow/open, guarded search-field entry, scrolling and up to six steps. The **floating live browser** expands into a touch-controlled mini browser with address bar and browser navigation. Actions appear in **Agent Activity**. Pages and search engines may block automated access.
- **Voice API choice:** The microphone can use a BYO **Whisper-compatible transcription API** (OpenAI/Groq/self-hosted compatible) instead of Apple Speech. Settings support transcription URL, model, a dedicated Keychain API key or reuse of chat-provider key.
- **Call mode:** Foreground voice-to-AI-to-spoken-answer loop, auto-pause detection after speech, animated call UI, mute/end controls, and turn-taking. It is not a phone call or 24/7 background service.
- **Free HTML uploads:** Default **paste.rs** raw text upload without a key; optional **Beacon** anonymous HTML hosting (normally expires after 24 hours). Gist/token and custom HTTPS hosting remain available. All public uploads are reviewed and fetched back to verify exact HTML bytes before HTMLApp import.
- **Message revisions:** Edit sent user messages, regenerate earlier assistant replies; older branch records are retained but excluded from active context, and stale derived memory/summary caches are invalidated.
- **UI refresh:** A five-tab iOS16-compatible interface, gradient chat bubbles, animated welcome orb/typing indicator, floating browser dock, haptics and improved materials.

See [docs/WEB_VOICE_HTMLAPP.md](docs/WEB_VOICE_HTMLAPP.md) for setup, safety constraints and the manual QA checklist. **These code changes have not passed a fresh Xcode compilation or real-device test.** The prior successful IPA build predates them.

## What's implemented in source

- **iOS 16.0** minimum; SwiftUI tabs for Chat, Agents, Memory, Tasks, Apps and Settings.
- **BYO AI API:** editable provider profiles, model IDs, OpenAI-compatible streaming chat, text adapters for Anthropic and Gemini, model discovery, connection tests, cancellation and token budget settings. API keys are in device-only Keychain, never CloudKit.
- **Chat:** persistent conversations, history search, streamed replies, stop generation, basic Markdown text display, text/PDF file import, selected photo OCR, Whisper-compatible API/Apple Speech dictation, call mode and spoken replies.
- **Local + iCloud storage:** generic Core Data records backed by `NSPersistentContainer` in safe local-only mode by default, and `NSPersistentCloudKitContainer` only when iCloud sync is enabled. Failed CloudKit setup uses a fresh local container opening the same SQLite file. Real iCloud sync requires correctly signed entitlements, a configured CloudKit container and cross-device tests. The storage model uses `tombstoneFlag` rather than the conflicting `deleted` attribute.
- **Memory:** editable/pinnable/scoped facts, heuristic extraction for explicit saved preferences, cost-budgeted recent context, rolling chat summaries (one additional model request after 18 new messages by default), relevant cross-chat summary recall, estimated prompt token diagnostics. Raw message archive is NOT resent by default. Memory search is lexical; embeddings and robust deletion propagation are future work.
- **Agent profiles and tool proposals:** custom instructions, model selection, allowed tool categories, explicit user confirmation and audit logs. Device tools include reminders, calendar events, local notifications, contacts count, location, clipboard, speech and tracked tasks.
- **HTMLApp:** bundles the exact skill file copied from `htmlapp/HTMLApp/Resources/HTMLApp-AI-App-Builder-SKILL.md`; AI generates/edit single self-contained HTML, review/edit and WKWebView preview, upload to anonymous paste.rs/Beacon, unlisted GitHub Gist or configured HTTPS publishing endpoint, then open the **existing** `htmlapp://import?url=<percent-encoded-HTTPS-URL>` deep link. The user saves the app in HTMLApp. Unlisted Gists are NOT private.
- **Manual-only unsigned IPA:** `.github/workflows/build-unsigned-ipa.yml` triggers on **workflow_dispatch only**. It generates a project with XcodeGen, parses Swift syntax, builds a device app without signing, checks deployment version, packages `Payload/ASSistant.app`, and uploads `ASSistant-unsigned.ipa`. There is a **manual opt-in** `run_simulator_smoke_test` input for running unit tests and launching on a simulator; it is **off by default**. No automatic build triggers are configured.
- Unit test source covering key memory and HTMLApp link behavior.

## How to build manually

1. On a Mac with Xcode and XcodeGen installed, run `xcodegen generate` from repository root.
2. Open `ASSistant.xcodeproj` and build the `ASSistant` scheme for an iOS 16+ simulator/device.
3. Configure your own signing team and CloudKit capability/container `iCloud.com.mekabrine.ASSistant` for actual cloud sync. Development identifiers may require adjusting the bundle/container IDs in `project.yml`, entitlements, and `Database.swift`.
4. Alternatively go to **GitHub → Actions → Build ASSistant Unsigned IPA → Run workflow** when you choose to spend build minutes. No workflows are started by source commits.

**Unsigned IPA warning:** This IPA is only a build artifact. Installing on an ordinary iPhone requires valid signing/provisioning; CloudKit capabilities require appropriately authorized entitlements. A sideloaded or ad-hoc signed package may not support iCloud.

## First-run setup

1. Open Settings → Add Provider. Enter your API URL, adapter type, model ID, authentication mode, and key. Optionally discover models or test the connection.
2. For HTMLApp publishing, choose the default anonymous paste.rs service (no key), optional Beacon, a GitHub Gist token, or an HTTPS upload endpoint returning `{"url":"https://yourhost/path/app.html"}`.
3. Use Chat normally, or Apps → Create with AI. Inspect the generated source and preview, then upload and tap **Open HTMLApp installation**.
4. Grant native tool and OS permissions only when prompted for an action you want.

## Prototype limitations and incomplete features

- The original source **built successfully** using the user-triggered Actions run on November 3, but **crashes on launch** were reported. The November 7 fixes have not been compiled or tested. The exact crash requires a device crash log; see `docs/CLAUDE_SPEC_ADOPTION.md`.
- CloudKit sync is wired into persistence, but cross-device conflict handling, CloudKit production schema deployment, and entitlement provisioning are not validated.
- Conversation message bodies and HTML app snapshots are stored as generic JSON blobs in Core Data; very large items may exceed CloudKit record limits. Migrate large attachments to CloudKit assets or bounded file storage.
- Full visual image-model requests, true background autonomous execution, browser automation, MCP servers, complete multimodal tool calling, multi-agent collaboration, a marketplace and push server are not part of this prototype. Scheduled **local notifications** work without a cloud worker, but iOS will not run arbitrary AI agents continually in the background.
- Remote model/tool-call formats vary; arbitrary API URLs are not universally protocol-compatible. OpenAI-compatible endpoints must actually implement the compatible schema.
- Tool requests are structured response proposals, not native provider function-calling APIs; all consequential actions require approval.
- HTML generation quality depends on the selected model and its output-token limit; generated code is untrusted and must be reviewed. Gist hosting makes app source public to anyone with its URL.
- CloudKit-synced data isn't end-to-end encrypted by this prototype's own key management; evaluate privacy requirements and encrypted sync before sensitive production use.

## If the app crashes on launch

The original database started CloudKit even when device signing might lack iCloud entitlements, retried loading a failed store on the same container, and used a `deleted` Core Data attribute which conflicts with managed-object deletion state. The source has been changed to start in local mode by default, use a fresh fallback store, preserve existing SQLite data, and rename the field to `tombstoneFlag` with a migration identifier. A source-level regression test covers the new model.

The first follow-up verification is to **manually** dispatch GitHub Actions with `run_simulator_smoke_test = true` (extra runner minutes, no automatic runs). Also reinstall a correctly signed IPA after preserving any existing app data. If the app still closes immediately, export the `ASSistant` crash report from iPhone Settings → Privacy & Security → Analytics & Improvements → Analytics Data or Xcode Devices and Simulators. Do not delete the app just to fix the crash if you have data you want to keep.

See [docs/CLAUDE_SPEC_ADOPTION.md](docs/CLAUDE_SPEC_ADOPTION.md) for the priorities adopted from the November 7 Claude specification, and [docs/PRODUCT_PLAN.md](docs/PRODUCT_PLAN.md) for the broader roadmap.
