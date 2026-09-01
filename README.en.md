# Baton

[English](README.en.md) · [中文](README.md)

**Give any existing Web Agent system an iPhone companion for voice-friendly input.**

## A familiar situation

More and more websites, enterprise applications, and Agent workspaces include an
Agent conversation. But typing on a computer is not always the easiest way to
respond. When you want to add context, ask a series of follow-up questions, or
talk while moving around, voice input on a phone is often more natural.

Building or installing a separate mobile app for every Agent service is costly,
repetitive, and likely to split conversation context.

Baton solves this with a standard **Companion Profile** protocol. When a service
adopts the protocol and displays a QR code in its current Web conversation, a
user can use the same Baton App to join conversations from different Agent
services.

Baton does not shrink the Web onto a phone. It **securely joins the phone to the
Agent conversation already in progress on the desktop**, making the phone a more
natural place for voice input. Baton is not a new Agent backend, a central
platform, or a replacement for an existing Web product.

After adopting Baton, the existing system still owns users, permissions,
business data, conversations, Agents, and model calls. It only implements a
small set of Baton endpoints and displays a QR code in the current Web
conversation. After scanning, the Baton App becomes a second client for that
conversation: messages stay in sync, while the Web keeps its original business
UI and capabilities.

This brings three direct benefits:

- **Preserve existing investment:** keep the Web app, Agent, models, and
  permission system instead of rebuilding a full mobile product.
- **Keep the context:** the Web client and iPhone see the same
  server-owned conversation.
- **Use each device well:** the computer remains the complex workspace; the
  iPhone provides local speech-to-text for frequent input.

```text
                     Your existing Web / Agent service
┌───────────────────────────────────────────────────────────────┐
│ Sign-in & permissions · business data · conversation · Agent  │
│ model / tools                                                  │
│                                                               │
│ Web UI ── pairing QR / Baton Companion Profile ── event log  │
└───────────────────────┬───────────────────────────────────────┘
                        │ one service, one conversation
              ┌─────────┴─────────┐
              ▼                   ▼
         Existing Web client     Baton iPhone App
         Full business workspace Voice-first companion
```

In short: **Baton does not move or copy your system. It relays the Agent
conversation already in progress to the phone.** The server remains the single
source of truth. The Web client and iPhone are peer clients and never exchange
messages directly.

### What Baton does not do

- It does not host users, business data, conversations, or model API keys.
- It does not require a new Agent framework, model provider, or Web stack.
- It does not mirror the browser or recreate the full business UI on a phone.
- It is not a third-party message relay between the Web app and the phone.

## How it works

1. A user opens an Agent conversation in a Baton-enabled Web page, which shows
   a QR code.
2. The user scans it with Baton and requests to join **that exact** conversation.
3. The Web page approves the device by default; the service may choose automatic
   approval for controlled environments.
4. The phone enters the same conversation, transcribes speech locally, lets the
   user edit it, and sends normal text messages.
5. The Web client and phone stay synchronized as peer clients; the server always
   owns the conversation state.

Scanning is not authorization by itself. A QR code contains only a short-lived
discovery URL. Whether the service uses Web approval or automatic approval, the
phone must claim its credential with a device-local `device_proof`. This lets an
enterprise Web app, Agent workspace, or internal system add a phone companion
without giving model keys to the app.

## Current capabilities

- Dynamic QR pairing; Web approval by default, with service-selected automatic
  approval available
- Saved multiple conversations, switching between them, and per-conversation
  availability checks
- Text chat, Markdown, streaming replies, and server-controlled static-image display in one shared conversation
- Stop generation, reconnect after interruption, and end a shared conversation
- iOS camera scanning; a Simulator Debug build can use the local demo service
- On-device iOS Speech-to-Text: edit the transcript, then send it as normal text

Image upload, camera/files, Tool UI, Agent-action approval, push notifications,
location, and generative UI are intentionally out of scope for now. Baton only
displays server-controlled static images and first focuses on making a shared
conversation reliable across devices.

## Add Baton to an existing system

Adoption does not migrate a business system to Baton. It adds a narrow
second-client access layer to an existing service:

| Your existing Web / Agent service continues to own | Baton provides |
| --- | --- |
| Sign-in, SSO, users, and business permissions | iOS Companion App and QR experience |
| Business data, pages, workspaces, and Tool UI | One-time device entry and local speech-to-text |
| Conversations, message storage, Agent runs, and model calls | Interoperability contract for snapshots, SSE, credentials, and recovery |
| Who may join, revoke, or end a conversation | Peer-client message presentation and text sending |

An existing Java Web app, Node service, or any Agent runtime does not need a new
model gateway or a rebuilt mobile app. It maps its own conversation model to
Baton's:

- service discovery and QR pairing;
- device approval and conversation-scoped credentials;
- conversation snapshots, messages, SSE, and recovery;
- device revocation and shared-conversation ending.

See [BATON_SPEC.md](BATON_SPEC.md) for the protocol and
[JAVA_INTEGRATION.md](JAVA_INTEGRATION.md) for Java Web integration. AG-UI may
be an optional server-side adapter, but it is not the iOS wire protocol.

### Documentation map

| If you want to… | Read |
| --- | --- |
| Understand the product and experience | This README |
| Implement interoperable servers or clients | [BATON_SPEC.md](BATON_SPEC.md) |
| Add Baton to an existing Java Web / Agent service | [JAVA_INTEGRATION.md](JAVA_INTEGRATION.md) |
| Run the local fixture | [mock_server/README.md](mock_server/README.md) |
| Understand client boundaries in the repository | [clients/README.md](clients/README.md) |

## Quick demo

The repository includes a small Python fixture for trying the complete Web ↔
iPhone relay flow. It is not a production backend.

```sh
python3 mock_server/mock_server.py
```

Then open [http://127.0.0.1:8787/](http://127.0.0.1:8787/) in a browser. The
page can create a QR code, approve a phone, and act as the other chat client.
For LAN testing on a physical device, the Simulator Debug demo connection,
optional OpenAI-compatible model replies, and fixture details, see
[mock_server/README.md](mock_server/README.md).

Open `clients/ios/Baton.xcodeproj` in Xcode to run on a Simulator or a configured
device. QR scanning requires a physical-device camera; the Simulator Debug build
keeps a local demo-service entry point. Baton follows the HTTP or HTTPS origin
selected by the adopting service. HTTP is visibly marked as unencrypted and can
fit a service-managed intranet or legacy deployment. HTTPS is strongly
recommended for the public internet or untrusted networks, but is not a
prerequisite for adopting Baton.

## Security principles

- The server is the single source of truth; the Web client and iPhone do not
  exchange messages directly.
- QR codes contain no token, history, or permanent credential. Device entry is
  Web-approved by default; automatic approval is a service-controlled option for
  controlled environments.
- Conversation credentials and pending messages live only in the iOS Keychain.
- Speech audio is recognized locally on the iPhone. Only user-edited text is sent
  to the service.
- Model API keys, cookies, tokens, and `device_proof` never enter the app, QR
  code, source code, or logs.
- HTTP supports existing services but cannot provide transport confidentiality or
  integrity. Baton makes this visible; the deploying service owns the network
  boundary and its risk.

## License

Baton is available under the [MIT License](LICENSE).
