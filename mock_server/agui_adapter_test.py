#!/usr/bin/env python3
"""Repeatable contract test for the narrow AG-UI-to-Baton translation."""
from ag_ui.core import (
    AssistantMessage,
    CustomEvent,
    MessagesSnapshotEvent,
    RunErrorEvent,
    RunFinishedEvent,
    RunStartedEvent,
    TextMessageContentEvent,
    TextMessageEndEvent,
    TextMessageStartEvent,
    UserMessage,
)
from ag_ui.encoder import EventEncoder

from agui_adapter import AGUIAdapter


CREATED_AT = "2026-08-26T10:32:12Z"
adapter = AGUIAdapter("conv_local", created_at=CREATED_AT)

# These are official SDK objects. Encoding them first verifies the pinned SDK
# still emits AG-UI's canonical event names before the adapter consumes them.
snapshot = MessagesSnapshotEvent(messages=[
    UserMessage(id="msg_user", content="你好"),
    AssistantMessage(id="msg_prior", content="已有回复"),
])
encoded_snapshot = EventEncoder().encode(snapshot)
assert '"type":"MESSAGES_SNAPSHOT"' in encoded_snapshot

drafts = adapter.adapt_many([
    snapshot,
    RunStartedEvent(threadId="conv_local", runId="run_42"),
    TextMessageStartEvent(messageId="msg_live", role="assistant"),
    TextMessageContentEvent(messageId="msg_live", delta="Baton"),
    TextMessageContentEvent(messageId="msg_live", delta=" adapter"),
    TextMessageEndEvent(messageId="msg_live"),
    RunFinishedEvent(threadId="conv_local", runId="run_42"),
])

assert [draft.type for draft in drafts] == [
    "conversation.snapshot", "run.started", "message.created", "message.delta",
    "message.delta", "message.completed", "run.completed",
]
assert drafts[0].data["conversation_id"] == "conv_local"
assert drafts[0].data["messages"] == [
    {"id": "msg_user", "client_message_id": None, "conversation_id": "conv_local", "role": "user",
     "content": [{"type": "text", "text": "你好"}], "created_at": CREATED_AT, "status": "completed"},
    {"id": "msg_prior", "client_message_id": None, "conversation_id": "conv_local", "role": "assistant",
     "content": [{"type": "text", "text": "已有回复"}], "created_at": CREATED_AT, "status": "completed"},
]
assert [draft.data.get("delta") for draft in drafts if draft.type == "message.delta"] == ["Baton", " adapter"]
assert drafts[-1].data == {"run_id": "run_42", "status": "completed"}

# An AG-UI run error has no run id; adapter state safely associates it with the
# currently running text/run and emits existing Baton terminal events.
failed = AGUIAdapter("conv_local", created_at=CREATED_AT)
error_drafts = failed.adapt_many([
    RunStartedEvent(threadId="conv_local", runId="run_error"),
    TextMessageStartEvent(messageId="msg_error", role="assistant"),
    RunErrorEvent(message="Model unavailable", code="upstream_unavailable"),
])
assert [(draft.type, draft.data) for draft in error_drafts[-2:]] == [
    ("message.failed", {"message": "Model unavailable", "code": "upstream_unavailable", "message_id": "msg_error"}),
    ("run.completed", {"run_id": "run_error", "status": "failed"}),
]

# Future AG-UI events do not leak into Baton SSE or crash the adapter.
assert adapter.adapt(CustomEvent(name="future-event", value={"x": 1})) == []
assert adapter.diagnostics[-1].code == "unsupported_agui_event"
assert adapter.adapt(RunStartedEvent(threadId="other-conversation", runId="run_wrong")) == []
assert adapter.diagnostics[-1].code == "conversation_mismatch"

print("AG-UI adapter test passed: snapshot, text stream, run success/error, and unknown-event isolation")
