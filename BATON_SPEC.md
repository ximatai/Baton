# Baton V1 Architecture

## Product definition

Baton is a universal iOS **Agent Companion**.  A desktop web application and
Baton are equal clients of one server-owned conversation.  Baton is not a
browser mirror and does not know how an agent, model, or business system is
implemented.

The V1 experience is deliberately narrow:

1. A web application creates a short-lived pairing session and renders its QR
   code.
2. The user scans it in Baton and joins that exact conversation.
3. Both clients receive the same message history and real-time updates.
4. The user dictates locally on iPhone, edits the resulting text, and sends it
   as a normal conversation message.

The server is the only source of truth.  No conversation data passes directly
between the browser and the phone.

```text
                     Companion Profile
    Web client  ─────────── Server ─────────── Baton for iOS
       full UI        conversation truth          voice-first UI
```

## Scope

Included: QR pairing, text and Markdown messages, history, streaming output,
stop generation, reconnect/resume, recently used services/conversations, and
on-device speech-to-text.

Explicitly deferred: image/camera/file input, **Agent action approvals** (HITL),
tool UI, generated UI, location, Face ID confirmation, and push notification.
The browser's confirmation of a *device pairing* is different: it is a V1
security requirement, not an Agent approval feature. The data and event shapes
remain extensible for the deferred capabilities.

## Protocol strategy

Baton defines a small **Companion Profile** for discovery, pairing, device
registration, and joining a conversation. A service may use
[AG-UI](https://docs.ag-ui.com/)—an open, event-based Agent-to-user-interface
protocol—behind an adapter, but Baton does not define a model API, tool
protocol, or agent-to-agent protocol.

### Optional AG-UI Agent adapter

The Companion Profile owns device discovery, pairing approval, device-bound
credentials, the conversation event log, SSE replay ids, and the Baton wire
format. [AG-UI](https://docs.ag-ui.com/) is an optional **agent-facing** adapter
behind that boundary; it neither replaces pairing nor becomes an iOS transport
contract. A Java service may map its Agent runtime to AG-UI, then map the small
V1 subset below into its normal Baton event log before serving iOS clients.

| AG-UI event | Baton event(s) | V1 mapping |
| --- | --- | --- |
| `MESSAGES_SNAPSHOT` | `conversation.snapshot` | Convert supported user/assistant text messages into Baton message envelopes. |
| `RUN_STARTED` | `run.started` | Copy `runId`. |
| `TEXT_MESSAGE_START` | `message.created` | Create a `streaming` user/assistant text message. |
| `TEXT_MESSAGE_CONTENT` | `message.delta` | Copy `messageId` and `delta`. |
| `TEXT_MESSAGE_END` | `message.completed` | Complete the matching message. |
| `RUN_FINISHED` | `run.completed` | Complete the matching run. |
| `RUN_ERROR` | `message.failed`, then `run.completed` | Attribute the error to the active message/run when known; terminal run data has `status: "failed"`. |

Tool, reasoning, state, custom, non-text, and otherwise unknown AG-UI events
are not Baton V1 features. The adapter records diagnostic metadata and safely
omits them from the Baton stream. This prevents upstream AG-UI evolution from
leaking directly into the iOS client. The reference adapter lives at
`mock_server/agui_adapter.py`; it emits drafts only, and the Companion server
assigns their ids/sequences and persists them like every other Baton event.

V1 mandates HTTPS plus Server-Sent Events (SSE).  A later version may advertise
WebSocket support, but does not alter event semantics.

## QR and pairing

The QR code contains a single HTTPS URL; it must not include bearer tokens,
conversation history, or a permanent credential.

```text
https://agent.example.com/.well-known/baton/pair/ps_7KDX23
```

`pairingId` is high entropy, expires in at most 60 seconds, and is bound by the
service to one conversation and the browser session that created it. A pairing
accepts exactly one device request. Pairing requires TLS. The iOS client
rejects HTTP except on a development-only build.

### Flow

```text
Web                Server                            Baton
 | POST pairing      |                                  |
 |<-- QR URL --------|                                  |
 |                                                       | scan URL
 |                    |<-- GET pairing document --------|
 |                    |<-- POST device join + proof ----|
 | show device       |----- pending ------------------->|
 | POST approve/deny |                                  | poll with proof
 |------------------>|----- token after approval ------>|
 |                    |                                  | open event stream
 |                    |<==== message events ===========>|
```

The browser shows the name of the requesting device and grants/denies it. This
confirmation is intentionally retained in V1: scanning a photograph of a QR
code alone cannot silently attach another phone.

Before joining, Baton creates a cryptographically random `device_proof` (at
least 256 bits) and retains it only locally. It submits that opaque value with
the join request and sends it in `X-Baton-Device-Proof` for every status poll.
It is never put in the QR URL, discovery document, browser page, or logs. The
server binds the request to it, so only the requesting device can read or claim
the eventual credential.

On approval, the server issues a conversation-scoped, short-lived access token
(recommended lifetime: 24 hours) bound to that registered device, plus an
opaque `session_id` used for exact remote revocation. Credential
claim is idempotent: while the pairing is still valid, the same request plus
the same `device_proof` receives the same token. This handles a lost response
without requiring the user to rescan. The pairing becomes `consumed` after its
first successful claim and still rejects every other device; it is not reusable
for a second join. Tokens are stored in Keychain. Revoking a device invalidates
all its refresh tokens and active streams.

### Pairing state machine

```text
created -- device joins --> pending -- web allows --> approved -- first claim --> consumed
   |                           |              \ web denies --> rejected
   +---------------------------+---------------------- expires --> expired
```

`consumed` means the invitation has yielded a credential, not that the approved
device has lost retry rights. A proof-bound retry returns the same token until
the pairing expires. `rejected` and `expired` never issue a token. Future Java
integrations must bind creation and approval to the existing authenticated web
session, store the request's proof securely, and apply these same transitions.

## Discovery document

`GET /.well-known/baton/pair/{pairingId}` returns no authority. It only lets the
app render a trustworthy pending-connection screen and submit a join request.

```json
{
  "protocol": "baton/1.0",
  "pairing_id": "ps_7KDX23",
  "expires_at": "2026-08-26T10:31:00Z",
  "service": { "id": "acme-erp", "name": "Acme ERP", "icon_url": "https://agent.example.com/icon.png" },
  "conversation": { "id": "conv_01J...", "title": "Sales analysis", "agent_name": "Sales analyst" },
  "endpoints": {
    "join": "https://agent.example.com/v1/baton/pairings/ps_7KDX23/requests",
    "approval": "https://agent.example.com/v1/baton/pairings/ps_7KDX23/approval",
    "conversation": "https://agent.example.com/v1/baton/conversations/conv_01J..."
  },
  "capabilities": { "text": true, "markdown": true, "streaming": true }
}
```

The app must validate the endpoint origins against the QR origin (same origin
in V1).  Remote icon URLs are optional and should be fetched as untrusted
content.

## Conversation HTTP API

All requests below use `Authorization: Bearer <access-token>` and return JSON.

The web server creates a QR pairing with `POST /v1/baton/pairings`, authenticated
as the web user. The response includes `pairing_id`, `qr_url`, an `approval_url`,
and `expires_at`; the resulting discovery document is the QR target described
above. This endpoint is browser/integrator-facing, not callable by Baton before
it holds a conversation-scoped token.

Pairing endpoints have distinct callers. In a production Java service, creation
and approval use its existing browser login/session and CSRF protection; the
mobile app only calls `join` and the proof-protected `status` endpoint.

| Operation | Endpoint | Caller | Purpose |
| --- | --- | --- | --- |
| Create | `POST /v1/baton/pairings` | Web | Creates a conversation-bound pairing and QR URL |
| Join | `POST /v1/baton/pairings/{id}/requests` | Baton | Submits `device_id`, display name, and `device_proof`; returns `request_id` |
| Status / claim | `GET /v1/baton/pairings/{id}/requests/{requestId}` | Baton | Requires `X-Baton-Device-Proof`; reports pending/rejected or returns the proof-bound token |
| Decide | `POST /v1/baton/pairings/{id}/approval` | Web | Browser-authorized `{ "decision": "approved" | "rejected" }` |

The local Python fixture also exposes the approval URL as a tiny HTML form. It
has no real login and is only a test stand-in for the Java application's
authenticated web page.

| Operation | Endpoint | Purpose |
| --- | --- | --- |
| Snapshot | `GET /v1/baton/conversations/{id}` | Conversation metadata, paged history, and an atomic resumable event cursor |
| Send | `POST /v1/baton/conversations/{id}/messages` | Idempotently creates a user message |
| Events | `GET /v1/baton/conversations/{id}/events` | SSE stream; supports `Last-Event-ID` |
| Stop | `POST /v1/baton/conversations/{id}/runs/{runId}:cancel` | Requests cancellation of a live agent run |
| Disconnect | `DELETE /v1/baton/devices/{deviceId}/sessions/{id}` | Revokes this conversation session |

Every client-created message carries a UUID `client_message_id`; retries with
the same value must return the originally created server message. Message
history is cursor paginated, newest page first.

### Atomic snapshot and SSE resumption

The snapshot response is one atomic read of the conversation state and its
event log position. It includes an `event_cursor`; the client sends
`event_cursor.id` as `Last-Event-ID` when opening the SSE connection.

```json
{
  "id": "conv_01J...",
  "messages": [],
  "next_cursor": null,
  "event_cursor": { "id": "evt_01J...", "sequence": 487 }
}
```

The server must not append an event between the returned message snapshot and
the recorded cursor. A valid `Last-Event-ID` replays only envelopes whose
`sequence` is strictly greater than that cursor. An absent `Last-Event-ID` is a
new live subscription and starts at the current tail; it is not an implicit
history replay. This deliberately makes the safe sequence:

```text
GET snapshot (including event_cursor) → GET events with Last-Event-ID → receive only later events
```

If the supplied id is unknown or has fallen outside retention, the server must
not replay from the beginning. It sends one complete SSE/Baton envelope of type
`conversation.resync`, with `data.reason = "cursor_unknown_or_expired"`, using
the latest retained cursor as its `id` and `sequence`. This control envelope is
not itself persisted in the Conversation log. The client must fetch a fresh
snapshot, replace its stored cursor with that snapshot's `event_cursor`, and
continue from there. Reusing the latest retained id also makes old clients that
persist every envelope id reconnect safely.

### Message model

```json
{
  "id": "msg_01J...",
  "client_message_id": "11EF7D8E-...",
  "conversation_id": "conv_01J...",
  "role": "user",
  "content": [{ "type": "text", "text": "按华东区域再拆分一下" }],
  "created_at": "2026-08-26T10:32:12Z",
  "status": "completed"
}
```

`content` is an ordered array from day one.  V1 renders and sends only
`text`; future items may include `image`, `file`, `citation`, or structured UI
references without breaking the message envelope.

### Required event envelope

Persisted SSE event ids are strictly increasing per conversation and retained
for a minimum of 24 hours. Every persisted envelope is emitted using standard
SSE framing: `id:`, `event:` (equal to the envelope's `type`), and JSON
`data:`. The per-connection `conversation.resync` control envelope above is the
only V1 exception to persistence; it still has the complete Baton envelope
shape and standard SSE framing.

```json
{
  "id": "evt_01J...",
  "sequence": 487,
  "type": "message.delta",
  "occurred_at": "2026-08-26T10:32:14Z",
  "data": { "message_id": "msg_01J...", "delta": "华东区域" }
}
```

V1 event types:

- `conversation.snapshot` — optional initial snapshot.
- `message.created` — immutable server-created message.
- `message.delta` — appended text for a streaming assistant message.
- `message.completed` — finalizes a message.
- `message.failed` — marks a message/run failed with a user-safe error.
- `run.started`, `run.completed`, `run.cancelled` — controls the stop button.
  A cancellation request is asynchronous: `run.cancelled` is emitted exactly
  once when the active run reaches terminal cancellation, after its streaming
  message has received `message.completed` with `status: "cancelled"`.
- `conversation.resync` — client must refetch history and replace its cursor.

Unknown event types must be ignored after recording diagnostic metadata. This is
the extension point for tool progress, client capability requests, approvals,
and multimodal content.

## Capability negotiation

The server advertises what it can render/accept; the device advertises what it
can provide.  Neither side assumes a capability merely because it exists in a
future specification.

```json
{
  "server": { "text": true, "markdown": true, "streaming": true },
  "device": { "text_input": true, "on_device_speech_to_text": true }
}
```

Future keys such as `camera`, `file`, `approval`, `location`, and
`notification` are reserved but unsupported by the V1 UI.

## iOS application boundaries

Use SwiftUI with Observation and Swift Concurrency.  Do not let views make
network requests or access Speech directly.

```text
Baton
├── App                 composition root, navigation, dependency container
├── Domain              Service, Conversation, Message, Pairing, Connection
├── CompanionProtocol   discovery/pairing API, auth, SSE codec, DTO mapping
├── Conversation        timeline state, send/retry/cancel, reconnect/resync
├── Speech              microphone capture and on-device transcription
├── Persistence         SwiftData cache + Keychain credentials
└── Features            Home, QR Scan, Pairing Approval, Conversation, Composer
```

Persist services, conversation metadata, cached messages, and last event ID in
SwiftData.  Persist access/refresh credentials only in Keychain.  The cache is
never authoritative; on opening a conversation, reconcile it with the server
snapshot and stream.

For iOS 26.5, `SpeechAnalyzer`/`SpeechTranscriber` is the primary implementation
and must be availability-checked.  Audio remains on device; only the edited
text is sent to the server.  The UX is: tap/hold microphone → live transcript →
edit → send.  The app must present microphone and speech-recognition permission
states clearly and remain fully usable with typed input when unavailable.

## Delivery order

1. Define Swift domain types and protocol DTOs with fixture-driven unit tests.
2. Implement a local mock Companion server for pairing, history, SSE, streaming,
   reconnection, and cancellation.
3. Build QR scan + approval + secure token persistence.
4. Build timeline, composer, and SSE resume/resync behavior.
5. Add on-device transcription and its permission/error states.
6. Replace the mock with a reference web-server adapter and publish the
   Companion Profile for integrators.

## Non-negotiable acceptance checks

- A newly scanned QR joins exactly the conversation selected by the web page.
- Both clients receive each other’s messages without a direct client-to-client
  channel.
- An interrupted stream resumes by event id or correctly refetches a snapshot.
- Repeating a send request cannot create a duplicate user message.
- Revoking the mobile device immediately prevents future access.
- No microphone audio is uploaded by Baton for V1 transcription.
