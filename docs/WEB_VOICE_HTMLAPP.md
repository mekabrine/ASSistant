# Web agent, call mode, Whisper and HTMLApp publishing

Implementation reference, 2026-11-07. The features below are committed source code, **not yet confirmed working on a real iOS device**. No CI workflows were triggered as part of this feature work.

## Web browsing and product research

On chat prompts explicitly requesting internet research, shopping or Amazon items:

1. AgentEngine performs a real foreground search with the native WebKit browser, including a search-engine fallback.
2. A bounded DOM snapshot gives the model the real page URL/title, at most 11.5k characters of readable text, visible HTTPS links with L# IDs, and discovered form-control IDs.
3. The agent may search, open public HTTPS links, follow L# links, refresh the current snapshot, scroll and fill search fields. It can submit a search form on supported sites with strict action checks.
4. It receives actual observations and then synthesizes an answer with observed source URLs. It may use at most six web steps per turn.
5. The browser stays in a small floating live WKWebView panel in chat. Expand to take touch control, use the URL/search bar, back/forward/reload, and return control to the agent.
6. Every auto-browse step has an activity log. Chat's Stop command cancels a pending browser navigation too.

**For the reported example** (“search on Amazon and find a navy blue apron resembling Wetzel's Pretzels uniforms”), the app should run an actual search (not only suggest keywords). Amazon and search engines may block automated access. In that case the answer must say access was blocked; it must not fabricate a price or product.

**Scope of browser access:** This uses an in-app WKWebView, not the Python/Tkinter/Chromium script itself. The uploaded `text_browser(2)(1).py` has a useful `GET /state`, `POST /cmd`, stable element ID, snapshot, click, and type design; the iOS version adapts those interaction ideas natively. The Python script is a desktop Playwright server bound to localhost, so it is **not a drop-in iOS runtime**. Do not expose its unauthenticated HTTP API publicly. A future optional remote runner may use a locked-down HTTPS proxy with user-provided credentials.

**Safety boundary:** Agent browser automation is read/search oriented. It cannot autonomously submit purchases, change accounts, send messages, click arbitrary account buttons, or bypass login/CAPTCHAs. Manual browser takeover handles actions needing human interaction. Browser page content is untrusted, and account input values/cookies are not extracted for the model. Domains must be public HTTPS; private-IP destinations and credentialed URLs are rejected by the URL validator, although browser redirects and DNS risk still warrant device/network testing.

## Whisper / transcription

Settings → **Voice and call mode**:

- Choose **Whisper-compatible API** (default), or Apple Speech (optional fallback).
- Set a transcription endpoint (e.g. `https://api.groq.com/openai/v1/audio/transcriptions` or `https://api.openai.com/v1/audio/transcriptions`). Leave blank to derive `audio/transcriptions` from the current chat provider base URL.
- Set model (default `gpt-transcribe` for new OpenAI compatible endpoints). For Groq's Whisper API use `whisper-large-v3-turbo` or `whisper-large-v3`. `whisper-1` is supported on providers that still offer it but has a scheduled deprecation on the official OpenAI platform.
- Dedicated STT key stored in Keychain, or reuse chat provider key. Enable key-free mode for a compatible self-hosted HTTPS endpoint.
- Tap microphone to record audio as bounded AAC/M4A; tap again to POST the audio using multipart form-data. The transcription inserts into the message composer.
- Full voice **Call mode** button in Chat: microphone → transcription → normal agent reply → native spoken TTS → microphone reopens once playback completes. The session is foreground-only. A voice-activity meter stops recording after a meaningful pause, after actual speech is detected. Native Apple TTS remains available offline.
- This does not depend on the iOS keyboard dictation key, and does not run permanently while the phone is locked. No on-device Whisper model has been bundled.

## Anonymous HTMLApp hosting

Apps → Generate → Review → Upload → Install in HTMLApp; chat can perform the full flow after explicit approval.

Select a service in Settings → **HTML publishing**:

| Mode | Credentials | Link duration | Notes |
| --- | --- | --- | --- |
| `paste` (default) | None | Service dependent | `POST https://paste.rs/`, response must be HTTP 201 and a raw HTTPS paste URL. HTTP 206 is rejected as truncated. Rate limited. |
| `beacon` | None | About 24 hours without an account | `POST https://beacon.host/v1/publish`, multipart `app.html`, response `fileUrl` from public HTTPS host. Rate limited. |
| `gist` | User token | Until deleted or service changes | Creates unlisted Gist. Unlisted is **not private**. |
| `custom` | Optional bearer key | Controlled by your server | `POST text/html`, response `{"url":"https://host/file.html"}`. |

**Important:** Each automatic upload can expose the complete HTML to anyone with its URL. No personal user data, passwords or API keys should be embedded in generated HTML. A secret-pattern scanner blocks certain literal credentials, but users must review source content. The service can reject uploads, change API behavior or go offline, and source links may expire.

The code verifies that a hosted URL is public HTTPS and that downloading it yields exactly the HTML bytes generated, before constructing the verified HTMLApp import deep link:

```
htmlapp://import?url=<URL-encoded-public-HTTPS-HTML-file-URL>
```

This matches `mekabrine/htmlapp/HTMLAppV3/RemoteHTMLImport.swift`. HTMLApp opens an import draft; the user must still Save App there.

## Chat revisions and UI

- Long-press messages → **Edit message** or **Regenerate answer**.
- Revised turns and earlier AI responses are retained as superseded records, removed from active context. A revision invalidates stale summaries and automatically extracted facts from retracted messages.
- The modernized SwiftUI interface uses a five-tab layout, ambient gradient materials, animated responses, a voice orb, a floating browser, call-mode pulse and haptics. It avoids iOS 17-only symbols/effects because minimum remains **iOS 16.0**.
- The activity timeline lists agent web actions and approval-gated tools.

## Manual QA checklist (not yet marked passed)

- [ ] Manually run build workflow with optional simulator smoke test; DO NOT schedule or auto-run.
- [ ] Launch on iOS 16 and 26 signed builds without crash; preserve existing local data.
- [ ] Configure OpenAI-compatible text provider and verify streaming replies.
- [ ] Tell agent: “Search on Amazon for navy blue aprons similar to Wetzel Pretzels uniforms.” Confirm real search, browser widget, evidence, links and no fake prices.
- [ ] Expand floating browser, tap links, navigate address bar, return control. Stop must cancel an active navigation.
- [ ] Ask to search private local contacts: ensure no public search is triggered.
- [ ] Record with Whisper provider, verify API endpoint, model, multipart payload and error messaging.
- [ ] Open Call mode: microphone captures a turn, AI replies, TTS speaks, and recording resumes. Test interruption, mute and call termination.
- [ ] Edit previous user message and regenerate an earlier AI response; stale content should not go to the model.
- [ ] Upload a simple standalone app to paste.rs and Beacon; inspect raw URL and ensure HTMLApp imports it.
- [ ] Test service rate limits, blocked pages, API 401, expired upload links, no STT key and microphone denial.
- [ ] Check Core Data/CloudKit behavior on correctly provisioned devices with the same Apple account.

## Architecture limits

- No continuously running local AI tasks when the app is suspended; an optional remote runner is necessary for 24/7 agent autonomy.
- No true desktop Chromium/Playwright automation inside iOS; the existing Python file is a reference for native browser design.
- No automatic purchases, account changes or bypasses. A user can manually control the browser.
- CloudKit cannot be guaranteed in an unsigned IPA, even if the code builds.
- GitHub Actions trigger remains `workflow_dispatch` only.
