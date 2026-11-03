# Prototype QA / manual acceptance checklist

**Status:** Source implementation only. Tests below are NOT asserted passed. No GitHub Actions workflow has been started by the assistant.

## Build acceptance
- [ ] In GitHub Actions, manually dispatch `Build ASSistant Unsigned IPA`.
- [ ] XcodeGen successfully generates `ASSistant.xcodeproj`.
- [ ] Swift syntax parses for app and tests.
- [ ] `xcodebuild` completes successfully using device SDK and `CODE_SIGNING_ALLOWED=NO`.
- [ ] `ASSistant-unsigned.ipa` contains `Payload/ASSistant.app/ASSistant`, a valid Info.plist, and 16.0 minimum OS.
- [ ] Verify the HTMLApp skill is copied into the resulting app bundle.
- [ ] Independently sign/provision before testing on a standard iPhone.

## Chat and providers
- [ ] Configure OpenAI-compatible provider + API key, stream a response, cancel mid-stream, and relaunch with chat history intact.
- [ ] Test Gemini and Anthropic adapters against real accounts; verify header handling.
- [ ] Test model discovery, provider switch by agent, auth-none local model (if supported), and no accidental token leakage into logs.
- [ ] Test 4k, 8k, 16k context limits with long conversations and verify old turns are not blindly resent.
- [ ] Import a plaintext file, PDF with extractable text, and photo OCR.
- [ ] Record/stop speech dictation and read an answer aloud on iOS 16.
- [ ] Validate failure modes: no key, no model, HTTP 401, rate limit, malformed SSE, cancellation, offline.

## Memory and data
- [ ] Verify fact extraction from 'remember that' and 'I prefer'; edit/pin/delete a memory.
- [ ] After 18 turns, verify rolling summary generation (extra model request) and preservation of past decisions.
- [ ] Verify relevant summaries from other chats recalled without irrelevant details.
- [ ] Test forced app termination and relaunch with data preserved.
- [ ] With valid Apple Developer signing and CloudKit container, test two devices, concurrent new chat messages, updates, delete and offline changes.
- [ ] Verify a build without CloudKit entitlement still uses local SQLite safely.
- [ ] Verify API keys do NOT sync to the other device and must be entered again there.

## Native tools and approvals
- [ ] Tool proposal is never executed without pressing Allow.
- [ ] Deny path creates an audit entry and performs no action.
- [ ] Agent tool-category restrictions block disallowed actions.
- [ ] Test reminder/calendar authorization on iOS 16 and iOS 17+.
- [ ] Test local notifications, location, clipboard, contacts enumeration and speech.
- [ ] Verify tool result is appended only after native API reports success.

## HTMLApp handoff
- [ ] Generate standalone HTML using bundled `HTMLApp-AI-App-Builder-SKILL.md`.
- [ ] Confirm source preview runs safely without privileged native bridge.
- [ ] Save/edit/revise app; verify previously assigned storage keys survive revisions.
- [ ] Publish to GitHub Gist, verify returned raw HTTPS URL is reachable and serves UTF-8 HTML.
- [ ] Confirm `htmlapp://import?url=<encoded HTTPS URL>` opens HTMLApp import screen.
- [ ] Verify HTMLApp requires user to Save App (opening link is NOT installation confirmation).
- [ ] One-step chat option: explicit consent, generate, publish, open HTMLApp.
- [ ] Test user cancels AI call, has no Gist token, or HTTP publishing fails; no fake-success message.

## Remaining architecture work (not in this prototype)
- True persistent background agents (requires optional server worker).
- Browser automation/sandbox execution and broader MCP/third-party connectors.
- CloudKit conflict-resolution UI, large CKAsset attachments, memory-derived-data deletion propagation.
- Native provider tool-call APIs and richer schemas; current agent proposals use validated JSON in assistant text.
- Robust HTML static security analysis / runnable automated app tests, model-generated code moderation.
- Advanced multi-agent delegation, shared skills marketplace and full app version diff/rollback.

## Debugging and budget policy
Only manually dispatch Actions after choosing to spend macOS minutes. Do not add push, PR, schedule, workflow_run, release, or repository_dispatch triggers to the build workflow. Source commits must never automatically invoke CI.
