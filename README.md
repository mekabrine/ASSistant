# ASSistant — iOS 16+ BYO-API agent prototype

Native SwiftUI assistant integrating user-configured AI APIs, private local-first data, CloudKit synchronization, contextual memory, native device tools and [HTMLApp](https://github.com/mekabrine/htmlapp) installation.

**Status: source-code prototype; a manually triggered GitHub Actions build completed successfully on Nov 8 before the browser/voice/sidebar expansion, but the new changes have not been built or device-verified. The user previously reported a crash on launch.** A successful install, permission flow, iCloud synchronization or IPA build must not be assumed until device tests pass.


## November 8 browser, memory, voice and chat redesign

These changes are **committed source code and still require a new Xcode/iOS simulator build**.

- **Passively view the AI browser:** Full-screen WebKit browser can be opened without taking control. Scrolling doesn't interrupt the agent; tapping links/buttons or typing in page controls hands you control. A prominent **Done — Return control to AI** button restores AI navigation. Sending a new message also releases manual browser control.
- **Human verification pause:** When an approved web task encounters an account sign-in, CAPTCHA, two-factor verification or similar protected step, the assistant can pause and request that you complete it. The AI never receives the password, form input values, cookies or security codes. Search engine challenge fallback tries **Google → Bing → DuckDuckGo**, not automated CAPTCHA bypass.
- **Multi-tab browser:** A small browser dock in chat expands to a full-screen list of separate browser tabs. Browsers share persistent WebKit website data across conversations; they do **not** automatically share Safari accounts. Settings lets you erase all in-app browser website storage. Agent actions select the relevant tab as they work. Signed-in page *content* may still be read by a web-enabled agent and relayed to your chosen model, so only enable web access on accounts you trust.
- **Memory directory:** Automatically saves additional explicit user preferences, likes/dislikes, routines, goals, work and project facts, with conservative sensitive-data screening. Memories have categories, short labels, timestamps, stable IDs, and local-only index/search/detail tools. The AI can request all short memory titles or filter by category and recent days, then ask for the full text by ID. Sensitive or out-of-scope memories are excluded.
- **Chat sidebar:** Responsive \`NavigationSplitView\` with searchable groups, pinned chats, create, rename, archive and delete. Collapsible on iPhone and iPad.
- **Automatically titled conversations:** Initial title from the first message, with optional low-cost model selected in Settings for automatic renaming after early messages and every fifth message. Title prompt uses at most 50 messages.
- **More expressive answers:** Markdown emphasis and links, scrollable syntax-preserving code blocks, Markdown tables, compact multiple-choice buttons, and deliberately constrained static HTML snippets. HTML previews block scripts and external links.
- **In-chat HTMLApp generation:** Agent or user can request standalone HTMLApp creation without leaving chat. A generated app card shows an interactive preview and Edit/Publish/Import actions. Public HTTPS publishing still requires explicit user approval and uses HTMLApp's existing \`htmlapp://import?url=...\` contract.
- **Free on-device speech:** Default dictation option is **WhisperKit on device**, with first-use model download, no dedicated transcription API key and no promise of an unlimited free cloud endpoint. Cloud Whisper-compatible BYO API and Apple Speech remain switchable in Settings. On-device model support/performance depend on phone resources and package compatibility.
- **Call mode agent narration:** Brief spoken progress phrases accompany browser actions while the call view remains focused on voice, followed by a normal spoken answer.
- **Chat attachment tray:** Expandable + button for Files, selected Photos and iOS Camera. Current images are processed with Vision OCR; general vision-model photo understanding is not yet available.

The privacy limits, browser login persistence and foreground iOS execution constraints remain important. No normal third-party app can silently bypass login/CAPTCHA or complete arbitrary system actions without appropriate permissions.

## November 7 feature expansion (source code, not device-verified)

- **Agent-controlled browser:** Explicit internet/shopping requests trigger real WKWebView web searches (with a Bing fallback), bounded read-only page observations, link follow/open, guarded search-field entry, scrolling and up to six steps. The **floating live browser** expands into a touch-controlled mini browser with address bar and browser navigation. Actions appear in **Agent Activity**. Pages and search engines may block automated access.
- **Voice API choice:** The microphone can use a BYO **Whisper-compatible transcription API** (OpenAI/Groq/self-hosted compatible) instead of Apple Speech. Settings support transcription URL, model, a dedicated Keychain API key or reuse of chat-provider key.
- **Call mode:** Foreground voice-to-AI-to-spoken-answer loop, auto-pause detection after speech, animated call UI, mute/end controls, and turn-taking. It is not a phone call or 24/7 background service.
- **Free HTML uploads:** Default **paste.rs** raw text upload without a key; optional **Beacon** anonymous HTML hosting (normally expires after 24 hours). Gist/token and custom HTTPS hosting remain available. All public uploads are reviewed and fetched back to verify exact HTML bytes before HTMLApp import.
- **Message revisions:** Edit sent user messages, regenerate earlier assistant replies; older branch records are retained but excluded from active context, and stale derived memory/summary caches are invalidated.
- **UI refresh:** A five-tab iOS16-compatible interface, gradient chat bubbles, animated welcome orb/typing indicator, floating browser dock, haptics and improved materials.

See [docs/WEB_VOICE_HTMLAPP.md](docs/WEB_VOICE_HTMLAPP.md) for setup, safety constraints and the manual QA checklist. **These code changes have not passed a fresh Xcode compilation or real-device test.** The prior successful IPA build predates them.

## Connected accounts and native actions (November 8)

- **Google / Gmail:** OAuth 2.0 PKCE sign-in with user-configured iOS OAuth client ID, device-local Keychain token storage and refresh, Gmail mailbox search, message reading, and sending after explicit approval. Gmail read permissions are restricted by Google and may require developer verification.
- **Spotify:** OAuth PKCE with the user's Spotify developer app client ID; identity, music search, playlists and current playback information. Approved playback actions support play/pause/next/previous, subject to account/device restrictions and Spotify Premium.
- **iOS Shortcuts:** Launch a named installed Shortcut via the system Shortcuts URL interface, with optional text input. This cannot enumerate all private Shortcuts or guarantee completion.
- **Phone:** Approved call requests open iOS Phone via a validated `tel:` URL. ASSistant does not secretly dial calls.
- **SMS / iMessage:** Prepare an Apple Messages compose screen with a recipient and body; the user presses Send. The result of the system composer is recorded, not carrier delivery.
- **Contacts:** Explicit permission-based local name/phone lookup.
- **Agent account permissions:** Per-agent Gmail and Spotify read access toggles, bounded read-only account tools, and approval-gated writes. Private email content is not placed into browser search queries or persistent audit logs.
- **UI:** Connected Accounts and Device Actions screens under Settings.

Google and Spotify require app registration and OAuth client IDs to work; the source cannot provide an unrelated developer's OAuth credentials. See [Connected accounts setup and QA](docs/CONNECTED_ACCOUNTS.md).

**Status:** These additions are committed but not yet Xcode-built or device-tested. The existing manual-only workflow has not been triggered by these commits.

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

- An earlier version **built successfully** in GitHub Actions on November 8, but **crashes on launch** were previously reported. Subsequent browser, voice, memory and sidebar changes have not been built or tested. The exact crash requires a device crash log; see `docs/CLAUDE_SPEC_ADOPTION.md`.
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
