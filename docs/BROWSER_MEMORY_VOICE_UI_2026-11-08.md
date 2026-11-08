# Browser, memory, chat, voice and UI expansion — November 8, 2026

These source changes are committed to ASSistant but have not yet been validated by a fresh Xcode simulator/device build. The GitHub Actions build workflow remains manual-only.

## Browser handoff and persistent logins

- Browser workspace has up to six independent WebKit pages. Tabs share ASSistant's persistent on-device WebKit website data, not Safari's cookies or provider OAuth tokens. Signed-in pages can be reused between chats.
- A full-screen browser view is observational at first. Scrolling does not transfer control; tapping links/buttons or interacting with input fields does. Manual browsing switches the agent into pause mode.
- When the user taps the large "Done — Return control to AI" button, browser agent execution resumes with a fresh page observation. Sending a new chat message also returns browser control and cancels stale in-flight agent work.
- CAPTCHA, login/password forms and code-verification pages request human assistance. Credentials and code values are never extracted into the model context. The AI cannot automatically enter those values.
- Internet search tries Google, Bing and DuckDuckGo in order. On an unsuccessful automatic search, it offers the page to the user for a manual check.
- Agents can create browsers, switch by UUID, list pages and navigate/read their selected active browser. The active tab automatically changes in the visible browser workspace. A control in Settings can clear stored website logins.

Browser automation is still foreground-limited, has a bounded action loop and cannot automatically purchase or submit protected account changes. A persistent session does not grant a safe exemption from user approval.

## Memory

- User statements with explicit long-term facts and preferences (for example "I prefer", "I love", "my favorite", "my name is", "my goal is") become categorized memories when they pass basic secret/sensitivity checks.
- Each memory can have a short title and category; older records without those optional fields remain readable.
- The Memory screen groups and filters by category and a last-7-days/30-days/year window, with expandable full text, editing and deletion.
- Memory tools support compact title/ID/category indexes by category and age, searching, and separate full-detail retrieval by UUID. Agent-proposed additional memory saves require user approval. Sensitive memory records are not automatically supplied.

The AI may occasionally misunderstand a preference or fact. Users remain able to inspect and correct saved memories.

## Voice

- Free on-device transcription uses the same WhisperKit approach as HTMLApp. The first request downloads a local speech model; device storage and internet are required once, but a third-party speech API key is not.
- Other choices remain configurable Whisper-compatible cloud API and Apple Speech.
- While call mode is doing web research, it can speak short progress statements instead of reading raw URL observations. The real answer is spoken after the agent finishes.
- Voice/call mode remains foreground-only and turn-based, not a telephone call and not an always-on background process.

## Conversation UI and apps

- The shared browser workspace and conversation selection persist across chat navigation.
- Chats have automatic initial titles and optional periodic re-titling using a user-selected inexpensive provider/model and up to 50 recent turns; title-generation calls can incur provider costs.
- The chat renders Markdown, tables, copyable code fences, multiple-choice buttons, and restricted static HTML preview blocks.
- Explicit HTMLApp-creation requests generate an interactive draft directly inside chat; public hosting and import are separate user actions. The preview uses its own isolated web context, not user-signed-in browser cookies.
- Expand the plus control to choose Files, Photos or Camera. Camera/photos currently contribute text via on-device Vision OCR; true multimodal pixel attachments still require provider-specific support.

## Manual acceptance checks

1. Run manual GitHub Actions with simulator smoke test; diagnose any compile errors before distributing.
2. Open a browser full screen, scroll without taking over, then type and confirm that AI pauses; tap Return control to AI and verify the agent continues.
3. Open two web browser pages, switch tabs during agent use and confirm active tab selection follows the agent. Sign into a test website; restart the app and check persistence.
4. Force Google search into a CAPTCHA and confirm Bing/DuckDuckGo fallback occurs before requesting human assistance.
5. Browse a login/security-code form; confirm handoff, no password extraction, and explicit completion.
6. Save preferences, list memory titles for last month, get full memory by ID, and verify sensitive memory stays excluded.
7. Create a fresh chat, send five messages, observe fallback and AI-generated titles, and pick a different model in Settings.
8. Send a table, code block, interactive choice and safe HTML preview; check layout and sandbox behavior.
9. Photograph printed text, use Photos, and attach a PDF via the expanded plus menu.
10. Run WhisperKit speech transcription on first download and again offline, then test call mode spoken browsing updates.
11. Ask to build an HTML app, preview it inside chat, edit it, and only publish when explicitly selected.
12. Confirm no automatic GitHub Actions trigger and no iOS 17-only API calls on the iOS 16 deployment target.

Known limitations: this source was not compiled in this session; remote search providers and websites may block scraping, WhisperKit model downloads depend on the network, and no claim of arbitrary in-app account transaction automation is made.
