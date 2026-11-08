# Browser, memory, call mode and chat workspace — November 8 upgrade

This file documents **source-code changes committed to main**, not a certified app release. A fresh manual Xcode/Actions build, simulator test and signed-device test are still necessary. The existing workflow remains `workflow_dispatch` only.

## Full-screen multi-browser workflow

- Tap the mini-browser thumbnail/status panel in Chat or choose **Open live browser** in the chat menu. The browser opens full screen **without automatically giving the user control**.
- Swiping/scrolling alone does not interrupt the agent. Touching a website link, button, form or input triggers the page-interaction handoff. Editing the browser address field also takes control.
- The agent can open up to six browser windows, switch between them by ID, and list names/URLs. The selected browser follows the tab the agent is working in.
- The website data store is persistent **within ASSistant** across chat changes and app restarts (not Safari). This lets users sign in manually and reuse those website sessions. Never extract passwords, OTPs, cookies or credentials for model prompts.
- An agent can explicitly request a user handoff for a CAPTCHA, login, security-code entry or other protected action. It waits, then continues only when **Done — Return control to AI** is pressed. This is attached to the requesting tab, even if the user looked at another tab. The app cannot solve CAPTCHA itself.
- Sending a new message relinquishes manual control and interrupts any previous pending request before starting a new one. Previous canceled results must not overwrite the new response.
- Public search runs Google, then Bing and DuckDuckGo if blocked by a human-verification page or a navigation error. This is best effort, not guaranteed access.
- A user-facing **Clear website logins and cookies** option signs out all ASSistant browser tabs without touching Safari or the separately configured Google/Spotify OAuth connections.
- Browser page text is *untrusted* input. Auto-browsing remains bounded and read/search focused; purchases, submissions, account modifications and payment actions require human interaction/approval. Browsing can fail when a site blocks WebKit automation.

## Sidebar and conversation improvements

- **iPad:** native `NavigationSplitView` sidebar stays open in regular width, with a header toggle to hide/show it. **iPhone:** compact sidebar starts hidden and opens from the sidebar button.
- Sidebar has search, chat sections by recency, pinned chats, rename, archive and delete.
- Chat title initially uses the first user turn, then optionally asks a selected lightweight provider/model to generate a concise title from at most the latest 50 visible messages. Refresh on the first answer and every five saved turns. Small-model calls consume the user's provider quota.
- Expand the **+** beside the composer for Files, Photos or Camera; the camera uses a native iOS permissioned capture interface. The existing vision path extracts text by OCR; this does **not** yet send raw photo pixels to every AI provider.
- AI replies render Markdown text, tables, copyable fenced code blocks, inline static HTML previews and interactive multiple-choice buttons. Inline HTML previews block scripts, remote URLs and unsafe tags, and use an ephemeral WebKit view with JavaScript disabled.
- When a chat requests an HTMLApp, ASSistant can generate a skill-driven standalone HTML draft directly in the conversation, show a preview/edit/publish/import card, and require explicit user action before publicly publishing it. The verified HTMLApp URL import scheme is unchanged.

## Memories and privacy

- High-confidence direct user statements (e.g. `I like …`, `I prefer …`, `my favorite …`, work/project/goal/routine statements) can become titled memories automatically. Inferred, speculative or sensitive facts should not be automatically stored.
- Long-term memory records support short titles, user-editable categories, timestamps, scopes, importance, sensitivity and pinning.
- Memory UI supports category and recency (seven days / 30 days / one year) filters plus expandable details and UUIDs.
- Agent tools `memory_list`, `memory_search`, `memory_get` return a small index by category/time, then full content only for a permitted exact ID. This reduces prompt token consumption; sensitive/private-scoped memory is not returned automatically.
- `memory_save` is an approval-gated tool. Agents may propose a category/title/text, but may not silently infer or persist secrets or other sensitive traits. Users can edit/delete memories in the Memory tab.
- Opt-in CloudKit syncing continues to require properly signed entitlements and testing on two devices; this does not establish app-level end-to-end encryption.

## Voice and Whisper

HTMLApp itself uses **WhisperKit on-device**, not an anonymous unlimited cloud STT API. ASSistant adopts that same key-free implementation, with a first-use model download (internet, storage and supported device required) and local transcription thereafter. A configurable user-supplied cloud Whisper-compatible endpoint and Apple Speech are still options under Settings.

Call mode is foreground-only and turn-based: recording, transcription, AI response and spoken TTS. It does not display live browser pages while speaking; it can announce short phrases about searches, opening pages, and comparison steps rather than reading whole pages/URLs. Protected actions still require browser handoff. It is not an always-on background phone call.


## November 8 UI and conversation-browser refinements

- **Draggable mini-browser.** The floating website thumbnail can be dragged around the chat. It stays within the screen and avoids the bottom composer area. Each chat remembers the dock position.
- **Browsers are chat-specific.** Each conversation owns its own browser tabs, current selection and navigation restore state; switching chats changes the visible tab set. Up to six tabs can be open per active chat. A few inactive live tab groups are retained in memory; older groups are released to reduce memory use and can be reloaded from saved state.
- **Tab management.** Long-press a browser tab to close it, or use the browser menu to close all tabs in the current chat. This does not sign you out of sites or clear any other chat’s saved pages.
- **Browser restoration.** A locally protected JSON record stores sanitized HTTPS URL, page title, a limited visible-text excerpt, approximate scroll position, tab ID and selection. This is saved on page updates, chat changes and app backgrounding. Restoring a chat after app relaunch navigates back to its saved pages. Site-dependent dynamic content, POST state, completed forms or the exact back/forward history may not be reproducible.
- **Login privacy.** Website cookies remain in ASSistant's own WebKit storage for signed-in browsing across chats, separate from Safari and native Google/Spotify OAuth. Saved URLs have common OAuth/code/token query parameters stripped. No cookies, passwords, code values, form values or page HTML are written into the browser restore record. Text excerpts are stored locally and excluded from device backup, but they can still contain personal page text; don't use the app on a shared unlocked device if that is a concern.
- **Fixed compact sidebar.** On iPhone, the chat list is a native-looking animated slide-over rather than a compact NavigationSplitView navigation destination. Opening it does not select/reselect the active conversation. Tapping a chat (including the current one) or closing the panel dismisses it. iPad retains its collapsible split-view sidebar.
- **Dynamic multiline composer.** Text input grows naturally with line wrapping until a bounded maximum height, then scrolls inside the input. A dedicated expand/collapse + panel places Files/Photos/Camera above the editor instead of squeezing its width. The chat content and composer are centered to readable widths on iPad, and keyboard dismissal follows conversation scrolling.
- **Per-chat unsent drafts.** Text that was typed but not sent is saved in locally protected per-chat files and restored when returning to that conversation. Sending clears its draft. Deleting a conversation also removes its locally saved browser record and draft.
- **Sidebar usability.** Search, recency grouping, conversation previews, selection emphasis, rename, pin, archive and delete.

### Manual verification

- [ ] Open and close the iPhone sidebar repeatedly without selecting anything: the active chat must stay put and the sidebar must remain open until dismissed
- [ ] Tap the already-selected chat while sidebar is open; verify it closes
- [ ] Make chats A and B, browse different websites in each, switch back and forth; verify tab isolation and remembered selection
- [ ] Force-quit and reopen, return to chat A and verify saved URL, title and approximate scroll position
- [ ] Sign in inside browser A; confirm session cookies remain usable in browser B without exposing them to the model
- [ ] Drag floating browser from right to left and near all safe screen edges; verify chat controls beneath remain tappable
- [ ] Rotate iPhone / test iPad and open keyboard while dock floats: the overlay should remain in a visible safe area
- [ ] Type a one-line and a long multiline message, then send and test keyboard dismissal
- [ ] Leave an unsent draft in A, write a different draft in B, kill/relaunch and confirm each is restored separately
- [ ] Delete a conversation, verify its browser and draft records no longer restore
- [ ] Run manual GitHub Actions build with simulator tests enabled; these changes have not been verified by a new Xcode build


## Mandatory manual testing

- [ ] Generate project with XcodeGen, resolve WhisperKit package and compile Debug/Release for iOS 16+.
- [ ] Run unit tests and launch app in simulator with `run_simulator_smoke_test` enabled on a **new manually dispatched workflow**. Do not re-run old commits.
- [ ] iPad split-view open/close, iPhone sidebar presentation, chat search/pin/rename/archive.
- [ ] New chat title, refresh at counts 5 and 10, provider/model override, missing API key.
- [ ] Browser full-screen visual observation and scroll; tapping or typing takes control; big Return control resumes agent on the right tab.
- [ ] Open multiple tabs, agent switches tabs, correct tab becomes visible, persistent sign-in across chat changes and app restart, user clearing all browser data.
- [ ] CAPTCHA detection fallback Google→Bing→DuckDuckGo; all three can fail. Verify manual handoff resumes without uploading form contents.
- [ ] Cancel an in-flight agent request by sending another chat message; no canceled response or older browser result should overwrite the new answer.
- [ ] Generate a table, code fence, 2–6 option choices and safe static HTML in message display.
- [ ] Use + to attach files, pick photos and capture camera images on actual iPhone.
- [ ] Save and filter preference memories; full lookup by UUID; ensure sensitive and cross-chat scoped records aren't leaked into unrelated prompts.
- [ ] Create HTMLApp inline in Chat, edit preview and publish only after explicit consent; verify HTMLApp remote import draft.
- [ ] Free offline Whisper first model download, second transcription offline, cloud API fallback, call-mode progress phrases and protected page handoff.
- [ ] Ensure unsigned build does not assume CloudKit entitlements, and the signing/install limitations are understood.

## Important limits

This code is an iOS SwiftUI/WebKit prototype and was not built on this system: it has no macOS/Xcode runtime here. Until a workflow/device test passes, do not present source commits as a verified working IPA. Sites may block automation; persistent website sign-in doesn't grant unrelated native API permissions; the browser cannot bypass CAPTCHAs or restrictions on protected account changes.
