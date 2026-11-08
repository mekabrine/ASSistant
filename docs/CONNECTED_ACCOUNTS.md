# Connected Accounts and Device Actions — implementation notes

**Status:** The source is committed, but these integrations have **not** yet been compiled/tested on an iOS device. No workflow was triggered automatically.

## Google / Gmail setup

1. In [Google Cloud Console](https://console.cloud.google.com/apis/credentials) create an OAuth consent configuration and a native **iOS OAuth client** associated with the app bundle identifier `com.mekabrine.ASSistant`.
2. Enable the **Gmail API** for the same Google Cloud project.
3. Use an approved iOS OAuth redirect configuration. ASSistant's current source registers the custom callback scheme `com.mekabrine.assistant` and uses URI `com.mekabrine.assistant:/oauth2redirect`. **Some client configurations require the SDK-provided reversed client-ID scheme instead.** If Google rejects this redirect, configure the OAuth client and regenerate `project.yml` with the allowed callback or integrate the official Google Sign-In iOS SDK; do not suppress callback checks.
4. On devices signed with a valid Apple certificate (required for reliable Keychain), open **Settings → Connected apps and accounts → Connect Google / Gmail and Spotify**.
5. Enter the Google iOS OAuth **client ID** (not a client secret), then tap **Sign in with Google**.
6. Add your own Google account to OAuth **test users** while the app is in testing. Google restricts Gmail read access; public apps may need OAuth app verification and restricted-scope assessment.
7. Connected Accounts can show identity, search your mailbox, and compose a Gmail message. Enable **Gmail** for your specific agent under the per-agent toggles if you want the AI to perform requested read-only Gmail searches.

Requested OAuth scopes: `openid`, `email`, `profile`, `gmail.readonly`, `gmail.send`. Google Gmail read scope is restricted. Sending is always confirmed by the user before the app performs the Gmail API POST. OAuth tokens are stored in the on-device Keychain, not CloudKit or the prompts. When a user asks the AI to summarize mail, the requested content is sent to the user-selected BYO model provider.

Relevant APIs:
- `GET https://gmail.googleapis.com/gmail/v1/users/me/messages?q=...`
- `GET https://gmail.googleapis.com/gmail/v1/users/me/messages/{id}?format=full`
- `POST https://gmail.googleapis.com/gmail/v1/users/me/messages/send`

## Spotify setup

1. Create an application at [Spotify for Developers](https://developer.spotify.com/dashboard) for your intended development account.
2. Add the iOS bundle ID `com.mekabrine.ASSistant` as required by your app's Spotify configuration and the exact redirect URI **`assistantspotify://callback`**.
3. In ASSistant **Settings → Connected Accounts**, enter the client ID and tap **Sign in with Spotify**.
4. Spotify authorization uses **PKCE S256**, so no Spotify client secret is bundled in the iOS app.
5. Test current track, playlist list and search. Enable Spotify access on the agent you want to use.
6. The agent can read search results/current playback, then propose playback modifications. Actions like play, pause, skip and previous require an explicit approval. Remote playback control may require **Spotify Premium**, an available playback device, and application permissions/development-mode allowlisting.

Requested scopes: `user-read-private`, `user-read-email`, `user-read-playback-state`, `user-read-currently-playing`, `user-modify-playback-state`, `playlist-read-private`, `user-library-read`.

The Spotify Web API does **not** grant arbitrary access to your account, and the Spotify app itself still handles playback through an eligible Spotify device.

## Shortcuts, Messages, Calls, and Contacts

Open **Settings → Phone, Messages, Shortcuts & Contacts** to test actions manually. Chat AI tool actions have separate approval prompts and visible audit logs.

- **Run a Shortcut:** Enter its **exact existing Shortcuts name**, optionally text input. ASSistant opens `shortcuts://run-shortcut?name=<encoded>`; this is an iOS handoff, not evidence that every action completed. Apps cannot list every personal Shortcut through this URL mechanism.
- **Phone:** Enter a validated number. ASSistant opens a `tel:` URL. The operating system and user manage actual call initiation; there is no background call-placement API for arbitrary third-party apps.
- **SMS/iMessage:** ASSistant presents Apple's `MFMessageComposeViewController` with the recipient and proposed text, and the user must tap **Send**. The app records whether the composer was sent/cancelled/failed, but not carrier delivery.
- **Contacts:** A lookup requests iOS Contacts permission and returns up to six matching contacts with numbers. The agent must ask permission before reading private contacts.

Account tools cannot bypass the system permission model, auto-send text messages, or silently initiate phone calls. Device calls require the user to approve the agent's proposal. Never use untrusted webpage text to authorize a send/call.

## Security and design

- PKCE verifier is random, bound to each sign-in session. S256 challenge is SHA256/verifier base64url; callback `state` is validated.
- Token exchange/refresh requests go only to official accounts endpoints; Gmail and Spotify read/write calls go to official API domains.
- Access/refresh tokens are stored in Keychain using `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and do **not** synchronize through CloudKit.
- User/agent per-service controls determine which accounts may be read. Read-only requests are bounded; Gmail content is excluded from the persistent agent audit and is never searched on a public web search engine.
- No changes are made by the user turning on account access alone; external writes still require confirmation.

## Required manual acceptance checks

- [ ] Run GitHub Actions `workflow_dispatch` only when intentionally chosen. Check iOS 16 compatibility and simulator launch.
- [ ] Google OAuth sign-in and cancel; wrong client ID/redirect should fail with a clear error.
- [ ] Gmail search unread messages and read a message. Do not expose mail to an unrelated agent/prompt.
- [ ] Gmail send requires approval, correctly encodes UTF-8 MIME, and returns a real Gmail message ID. Test user cancellation.
- [ ] Spotify login, playlist/read search, player pause/skip with free and Premium accounts; failures must be visible.
- [ ] Token expiration and refresh; disconnect then verify account reads stop.
- [ ] Shortcuts opening by name with user-installed Shortcut; verify a missing Shortcut is not reported as successfully executed.
- [ ] Messages compose, cancel and send on a physical phone; carrier delivery is not guaranteed.
- [ ] Phone app handoff, invalid number rejection, and contacts denied/authorized behavior.
- [ ] Per-agent permission toggles; verify missing approval never sends Gmail or modifies Spotify state.
- [ ] Run `xcodebuild` and unit tests; no on-device launch has been certified from source alone.

## Current limits and future expansion

This adds Gmail/Spotify and selected Apple native tools, **not every external service**. Google Drive, Google Photos, direct calendar API syncing, Slack, Discord, WhatsApp/Instagram DMs, arbitrary app automation, server background workers, direct system-wide phone/Messages access, and unrestricted Apple Shortcuts enumeration require additional OAuth scopes, provider-specific APIs, or platform capabilities. Each integration must respect the provider's terms and user approval.

Reference documentation: [Google installed-app OAuth](https://developers.google.com/identity/protocols/oauth2/native-app), [Google iOS Sign-In](https://developers.google.com/identity/sign-in/ios/start-integrating), [Gmail API send](https://developers.google.com/workspace/gmail/api/guides/sending), [Spotify PKCE](https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow), [Spotify redirect URIs](https://developer.spotify.com/documentation/web-api/concepts/redirect_uri), [Apple MessageUI](https://developer.apple.com/documentation/messageui/mfmessagecomposeviewcontroller).
