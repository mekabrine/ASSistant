# ASSistant — iOS AI Agent

A native, iOS 16.0+ bring-your-own-API AI assistant with persistent contextual memory, iCloud chat sync, native permission-based tools, and integration with [HTMLApp](https://github.com/mekabrine/htmlapp) for user-created mini apps.

> Planning stage. No working iOS app or IPA has been built yet.

## Non-negotiables

- Minimum deployment target **iOS 16.0**.
- User-managed AI provider base URLs, keys, models, and adapters; credentials stored in Keychain, never in generated HTML.
- Local-first chat and memory; optional iCloud/CloudKit sync for user chats, settings, agents, memory, tasks, and app metadata.
- Strong cost-controlled memory retrieval: persistent factual memory + per-chat summaries + cross-chat recall + recent turns; never transmit whole history by default.
- Integrate existing HTMLApp runtime and native capability registry. Generated apps require preview, permission review, and explicit installation.
- GitHub Actions builds use **workflow_dispatch only**, never push/PR/schedule triggers.
- Manual GitHub Actions workflow should produce an unsigned, unsigned-packaged `.ipa` artifact. Device installation requires a subsequent compatible signing/provisioning process; iCloud entitlements must be provisioned correctly.
- Never trigger paid build workflows as part of code edits without explicit user instruction.

## Initial plan

See [docs/PRODUCT_PLAN.md](docs/PRODUCT_PLAN.md) for UX, features, security, memory, synchronization, build/release design, and phased milestones.

## Proposed structure (not yet implemented)

```
ASSistant/
  ASSistant/                 # SwiftUI iOS target
    App/                     # app lifecycle, navigation
    Features/                # Chat, Agents, Memory, Tasks, Apps, Settings
    Core/                    # models, storage, networking, AI adapters
    Services/                # CloudKit, permissions, tools, HTMLApp integration
  ASSistantTests/
  docs/
  project.yml                # XcodeGen project; iOS 16 deployment target
  .github/workflows/
    build-unsigned-ipa.yml   # manual dispatch only
```

## Repo integration

HTMLApp already supports WKWebView mini apps, a native bridge, guarded storage and permissions, and its own manual IPA workflow. ASSistant should reuse its documented app runtime boundaries, NOT assume an undocumented install URL exists. Cross-app install URL/manifest, return callbacks, and capability negotiation must be designed and implemented in coordination with HTMLApp.

## Key limitations

An unsigned IPA is a build artifact, **not directly installable on stock iOS**. CloudKit requires Apple provisioning/signing entitlements; an arbitrary signature or unsupported sideload environment cannot guarantee that iCloud synchronization works.
