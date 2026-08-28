# Baton Companion Profile 1.0

> **受众：计划让 Web/Agent 服务接入 Baton 的服务端、Web 与移动端实现者。**
> 本文是 V1 的对外协议契约；产品介绍见 `README.md`，仓库内部编码约定见 `AGENTS.md`。

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
stop generation, reconnect/resume, and on-device speech-to-text.

Explicitly deferred: image/camera/file input, **Agent action approvals** (HITL),
tool UI, generated UI, location, Face ID confirmation, and push notification.
Device pairing is different from an Agent approval feature: V1 supports a
server-controlled `manual` or `auto` pairing policy. The data and event shapes
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

V1 uses service-selected HTTP or HTTPS plus Server-Sent Events (SSE). The QR
URL chooses the transport; there is no separate transport negotiation. HTTPS
is strongly recommended, but HTTP remains supported so an existing intranet or
legacy Web system can adopt Baton without first changing its deployment. Baton
visibly marks an HTTP conversation as unencrypted. A later version may
advertise WebSocket support, but does not alter event semantics.

## QR and pairing

The QR code contains a single absolute HTTP or HTTPS URL; it must not include bearer tokens,
conversation history, or a permanent credential.

```text
https://agent.example.com/.well-known/baton/pair/ps_7KDX23
```

`pairingId` is high entropy, expires in at most 60 seconds, and is bound by the
service to one conversation and the browser session that created it. A pairing
accepts exactly one device request. The service selects `http` or `https` in
this URL; every endpoint in the discovery document, including `poll_url`, must
have the exact same origin (scheme, host, and port). Clients must not silently
upgrade or downgrade the transport. An HTTP connection is not confidential or
integrity protected by the transport, so the Baton UI must persistently mark it
as unencrypted; deployers must limit it to a network whose risk they accept.

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
its active token and streams. Refresh-token semantics are intentionally outside
Baton V1.

### Pairing approval policy and state machine

```text
manual: created -- device joins --> pending -- web allows --> approved -- first claim --> consumed
                                  |              \ web denies --> rejected
auto:   created -- device joins -----------------> approved -- first claim --> consumed
   +---------------------------------------------- expires --> expired
```

`consumed` means the invitation has yielded a credential, not that the approved
device has lost retry rights. A proof-bound retry returns the same token until
the pairing expires. `rejected` and `expired` never issue a token. `manual` is
the required default: the Web user explicitly allows or rejects the device.
For `auto`, the server atomically approves the first valid device join; it must
not depend on an iOS-provided preference or permit a second device. The active
QR is therefore a short-lived capability to enter that exact Conversation, so
the service must expose `auto` only where that risk is acceptable. Future Java
integrations must bind creation and manual approval to the existing authenticated
web session, store the request's proof securely, and apply these same transitions.

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
  "approval_mode": "manual",
  "endpoints": {
    "join": "https://agent.example.com/v1/baton/pairings/ps_7KDX23/requests",
    "approval": "https://agent.example.com/v1/baton/pairings/ps_7KDX23/approval",
    "conversation": "https://agent.example.com/v1/baton/conversations/conv_01J..."
  },
  "capabilities": { "text": true, "markdown": true, "streaming": true }
}
```

The app must validate the endpoint origins against the QR origin (same origin
in V1). `approval_mode` is a server declaration: absent means `manual` for
backward compatibility; valid values are `manual` and `auto`. The App may use
it only to explain the pending state—it must always wait for the proof-bound
status/claim response before storing a credential. `capabilities` is a **server
discovery declaration** in V1, not a negotiation exchange: `text` is required
and must be `true`; `markdown` and `streaming` declare optional server behavior.
A client may safely ignore an unknown key. Remote icon URLs are optional and
should be fetched as untrusted content.

## Conversation HTTP API

All endpoints return JSON. Baton Conversation calls use
`Authorization: Bearer <access-token>`; pairing creation/approval use the
host Web application's existing authenticated session and CSRF protection.

The web server creates a QR pairing with `POST /v1/baton/pairings`, authenticated
as the web user. Its optional `approval_mode` is `manual` by default; a service
may set it to `auto` using its own authorization and Conversation policy. The
response includes `pairing_id`, `qr_url`, an `approval_url`, `approval_mode`,
and `expires_at`; the resulting discovery document is the QR target described
above. This endpoint is browser/integrator-facing, not callable by Baton before
it holds a conversation-scoped token.

Pairing endpoints have distinct callers. In a production Java service, creation
and approval use its existing browser login/session and CSRF protection; the
mobile app only calls `join` and the proof-protected `status` endpoint.

| Operation | Endpoint | Caller | Purpose |
| --- | --- | --- | --- |
| Create | `POST /v1/baton/pairings` | Web | Creates a conversation-bound pairing and QR URL |
| Join | `POST /v1/baton/pairings/{id}/requests` | Baton | Submits `device_id`, display name, and `device_proof`; returns `request_id`; `auto` pairings are atomically approved here |
| Status / claim | `GET /v1/baton/pairings/{id}/requests/{requestId}` | Baton | Requires `X-Baton-Device-Proof`; reports pending/rejected or returns the proof-bound token |
| Decide | `POST /v1/baton/pairings/{id}/approval` | Web | Only `manual`; browser-authorized `{ "decision": "approved" | "rejected" }` |

The successful Join response is `202` and includes an absolute
`poll_url`, for example:

```json
{
  "pairing_id": "ps_7KDX23",
  "request_id": "pr_01J...",
  "status": "pending",
  "poll_url": "https://agent.example.com/v1/baton/pairings/ps_7KDX23/requests/pr_01J...",
  "retry_after_seconds": 2
}
```

For `manual`, `status` is `pending` until the Web decision. For `auto`, the
server returns `approved` after atomically binding the first valid proof; the
App still uses `poll_url` and `X-Baton-Device-Proof` to claim the credential.
An auto response must never directly embed the access token in the Join body.

`poll_url` is not a relative path. It must include scheme and host, use the
same service-facing origin as the discovery URL and Join endpoint, and be directly
reachable by the iPhone that created the request. It may contain the opaque
request id, but must never contain an access token or `device_proof`; claim
continues to require `X-Baton-Device-Proof`. A client must reject a relative,
malformed, cross-origin, or otherwise unreachable poll URL rather than trying
to infer a base URL.

The local Python fixture also exposes the approval URL as a tiny HTML form. It
has no real login and is only a test stand-in for the Java application's
authenticated web page.

| Operation | Endpoint | Purpose |
| --- | --- | --- |
| Snapshot | `GET /v1/baton/conversations/{id}` | Conversation metadata, bounded initial history, live runs, and an atomic resumable event cursor |
| Send | `POST /v1/baton/conversations/{id}/messages` | Idempotently creates a user message |
| Events | `GET /v1/baton/conversations/{id}/events` | SSE stream; supports `Last-Event-ID` |
| Stop | `POST /v1/baton/conversations/{id}/runs/{runId}:cancel` | Requests cancellation of a live agent run |
| End | `POST /v1/baton/conversations/{id}:end` | Ends the shared conversation as a server-side transaction; requires the service's `conversation:close` permission |
| Disconnect | `DELETE /v1/baton/devices/{deviceId}/sessions/{id}` | Revokes this conversation session |

Every client-created message carries a UUID `client_message_id`; retries with
the same value must return the originally created server message.

### Ending a shared conversation

`POST ...:end` is a service-authorized transaction, not a client-side clear.
The caller must have the service's `conversation:close` permission; a valid
credential without that permission receives `403 conversation_close_forbidden`.
The request carries an `Idempotency-Key` UUID. The first accepted request
atomically marks the Conversation closed, invalidates every active
conversation session token, expires every unclaimed/pending pairing for that
Conversation, and fences any active Agent run. It then appends and broadcasts
exactly one persisted `conversation.closed` envelope and closes established
event streams after that envelope is flushed.

Fencing means the server asks the Agent runtime to stop, but does not wait for
an external model provider. Once closed, no worker may append a delta,
completion, failure, or new message; a late result is discarded. The terminal
`conversation.closed` event supersedes any in-flight run state. A retry with
the same idempotency key returns the original successful result without a
second transition or event, even though that session is otherwise revoked.
All other future use of a revoked token fails with `401 session_revoked`.

A closed Conversation is never reset or reopened. To start again, the Web
application creates a **new Conversation with a new `conversation_id`** and
then creates a new pairing. Its event sequence starts independently; ids or
sequences from the closed Conversation are never reused.

### Atomic snapshot and SSE resumption

The snapshot response is one atomic read of the conversation state and its
event log position. It includes an `event_cursor`; the client sends
`event_cursor.id` as `Last-Event-ID` when opening the SSE connection.

```json
{
  "id": "conv_01J...",
  "messages": [],
  "history_truncated": false,
  "active_runs": [
    { "run_id": "run_01J...", "status": "running", "message_id": "msg_01J..." }
  ],
  "event_cursor": { "id": "evt_01J...", "sequence": 487 }
}
```

V1 has no client history-pagination API. `messages` is the complete initial
history window, ordered oldest to newest, with a hard maximum of the newest
200 messages and 1 MiB of UTF-8 serialized message content (whichever limit
is reached first). If older history does not fit, the server returns the newest
whole-message window and `history_truncated: true`; it never returns a partial
message and it does not expose `next_cursor`. Old history remains a concern of
the host Web product, not Baton V1. `active_runs` is optional and defaults to
an empty array for clients that predate it. When present it is atomically read
with the history and cursor, and lists only non-terminal runs as
`{run_id, status, message_id?}`. Its `run_id` is the value the client must
retain after reconnect so it can continue to offer Stop.

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

### SSE transport and sequence rules

The events endpoint returns `200 Content-Type: text/event-stream; charset=utf-8`
and `Cache-Control: no-cache`, with buffering disabled where the hosting stack
requires it. Persisted envelopes are UTF-8 JSON sent with standard `id:`,
`event:`, and `data:` fields followed by one blank line; `event` equals the
envelope `type`. Comment heartbeats are allowed and carry no Baton envelope.
HTTP error responses are JSON, never a partial SSE event.

The server emits each retained envelope once in strictly increasing `sequence`
order for a subscription/replay and never intentionally skips a retained
sequence. A client persists the last accepted `{id, sequence}`. It may ignore
an exact duplicate of an already accepted envelope, but a changed id for an
old sequence, a non-increasing new sequence, or a gap (`sequence > previous +
1`) is a continuity failure: it must stop applying events and fetch a fresh
snapshot. The server uses `conversation.resync` for an unknown/expired cursor;
clients use the same snapshot recovery path for transport or sequence failures.

Stable V1 HTTP/error semantics are: `401 invalid_token` or `session_revoked`
for missing, invalid, or revoked credentials; `403 conversation_close_forbidden`
for a valid credential lacking close permission; `404 conversation_not_found`
for an unknown id; and `410 conversation_closed` only when a request was
authenticated before the close boundary and is rejected by that boundary.
Clients treat `401 session_revoked`, `410 conversation_closed`, and
`conversation.closed` as terminal: discard local credential and return to
pairing. Other errors are recoverable only according to their explicit code.

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
- `conversation.closed` — exactly one persisted terminal envelope for a close
  transaction. It is delivered to every stream already attached to the
  Conversation, after which clients discard credentials and return to pairing.
  No later envelope may be appended for that Conversation.

Unknown event types must be ignored after recording diagnostic metadata. This is
the extension point for tool progress, client capability requests, approvals,
and multimodal content.

## Capabilities

The discovery document's `capabilities` object is the only V1 capability
surface. It declares what this server accepts or emits for this Conversation;
it is not a request for device capabilities and it does not grant permission.
`text: true` is mandatory. `markdown` and `streaming` may be declared when
implemented. The iOS app is voice-capable by local product design, but it does
not advertise that fact on the wire in V1.

Bidirectional capability negotiation, per-device capabilities, and future keys
such as `camera`, `file`, `approval`, `location`, and `notification` are
explicitly deferred. A future version must define their lifecycle and fallback
semantics rather than treating unknown keys as negotiated support.

## Integration acceptance requirements

- A newly scanned QR joins exactly the conversation selected by the web page.
- Both clients receive each other’s messages without a direct client-to-client
  channel.
- An interrupted stream resumes by event id or correctly refetches a snapshot.
- Repeating a send request cannot create a duplicate user message.
- Revoking the mobile device immediately prevents future access.
- No microphone audio is uploaded by Baton for V1 transcription.
