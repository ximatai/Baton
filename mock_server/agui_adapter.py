"""Small, one-way AG-UI-to-Baton event boundary.

This module deliberately translates *from* AG-UI's official Python models
*to* Companion Profile event drafts. Pairing, device credentials, replayable
event ids, and the SSE connection remain owned by the Baton service. The
adapter never becomes part of the iOS wire contract: its caller persists each
draft through the normal Baton event log before publishing it over SSE.

Only the V1 text/run subset is supported. Unsupported AG-UI events are safely
ignored and retained as diagnostics, making an upstream protocol addition
observable without breaking a mobile conversation.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import logging
from typing import Any, Iterable

from ag_ui.core import (
    AssistantMessage,
    BaseEvent,
    MessagesSnapshotEvent,
    RunErrorEvent,
    RunFinishedEvent,
    RunStartedEvent,
    TextMessageContentEvent,
    TextMessageEndEvent,
    TextMessageStartEvent,
    UserMessage,
)


LOGGER = logging.getLogger(__name__)


@dataclass(frozen=True)
class BatonEventDraft:
    """An event without server-assigned id, sequence, or occurred_at fields."""

    type: str
    data: dict[str, Any]


@dataclass(frozen=True)
class AdapterDiagnostic:
    code: str
    event_type: str
    detail: str


class AGUIAdapter:
    """Maps the deliberately small AG-UI V1 subset into Baton event drafts."""

    def __init__(self, conversation_id: str, *, created_at: str | None = None):
        self.conversation_id = conversation_id
        self.created_at = created_at
        self.diagnostics: list[AdapterDiagnostic] = []
        self._active_run_id: str | None = None
        self._streaming_message_ids: list[str] = []

    def adapt_many(self, events: Iterable[BaseEvent]) -> list[BatonEventDraft]:
        drafts: list[BatonEventDraft] = []
        for event in events:
            drafts.extend(self.adapt(event))
        return drafts

    def adapt(self, event: BaseEvent) -> list[BatonEventDraft]:
        """Return zero or more Baton event drafts for one official AG-UI event."""
        if isinstance(event, MessagesSnapshotEvent):
            return [BatonEventDraft("conversation.snapshot", {
                "conversation_id": self.conversation_id,
                "messages": self._snapshot_messages(event),
            })]
        if isinstance(event, RunStartedEvent):
            if not self._matches_conversation(event):
                return []
            self._active_run_id = event.run_id
            return [BatonEventDraft("run.started", {"run_id": event.run_id})]
        if isinstance(event, TextMessageStartEvent):
            if event.role not in {"user", "assistant"}:
                self._diagnose("unsupported_message_role", event, f"role {event.role!r} is outside Baton V1")
                return []
            self._streaming_message_ids.append(event.message_id)
            return [BatonEventDraft("message.created", self._message(
                message_id=event.message_id, role=event.role, text="", status="streaming", event=event
            ))]
        if isinstance(event, TextMessageContentEvent):
            return [BatonEventDraft("message.delta", {"message_id": event.message_id, "delta": event.delta})]
        if isinstance(event, TextMessageEndEvent):
            self._remove_streaming(event.message_id)
            return [BatonEventDraft("message.completed", {"message_id": event.message_id, "status": "completed"})]
        if isinstance(event, RunFinishedEvent):
            if not self._matches_conversation(event):
                return []
            self._active_run_id = None
            return [BatonEventDraft("run.completed", {"run_id": event.run_id, "status": "completed"})]
        if isinstance(event, RunErrorEvent):
            # AG-UI's RUN_ERROR has no run id. Attribute it to the current run
            # and newest live text message, then emit Baton’s existing terminal
            # run event so V1 clients clear their stop state.
            message_id = self._streaming_message_ids[-1] if self._streaming_message_ids else None
            failed = {"message": event.message, "code": event.code or "agent_error"}
            if message_id:
                failed["message_id"] = message_id
                self._remove_streaming(message_id)
            drafts = [BatonEventDraft("message.failed", failed)]
            if self._active_run_id:
                drafts.append(BatonEventDraft("run.completed", {
                    "run_id": self._active_run_id, "status": "failed",
                }))
            self._active_run_id = None
            return drafts
        self._diagnose("unsupported_agui_event", event, "ignored by Baton V1 adapter")
        return []

    def _snapshot_messages(self, event: MessagesSnapshotEvent) -> list[dict[str, Any]]:
        messages: list[dict[str, Any]] = []
        for message in event.messages:
            if not isinstance(message, (UserMessage, AssistantMessage)):
                self._diagnose("unsupported_snapshot_message", event, f"role {message.role!r} is outside Baton V1")
                continue
            text = self._text_content(message.content)
            if text is None:
                self._diagnose("unsupported_snapshot_content", event, f"message {message.id!r} has non-text content")
                continue
            messages.append(self._message(
                message_id=message.id, role=message.role, text=text, status="completed", event=event
            ))
        return messages

    @staticmethod
    def _text_content(content: Any) -> str | None:
        if isinstance(content, str):
            return content
        if isinstance(content, list) and all(getattr(item, "type", None) == "text" for item in content):
            return "".join(item.text for item in content)
        return None

    def _message(self, *, message_id: str, role: str, text: str, status: str, event: BaseEvent) -> dict[str, Any]:
        return {
            "id": message_id,
            "client_message_id": None,
            "conversation_id": self.conversation_id,
            "role": role,
            "content": [{"type": "text", "text": text}],
            "created_at": self._event_time(event),
            "status": status,
        }

    def _event_time(self, event: BaseEvent) -> str:
        if event.timestamp is not None:
            return datetime.fromtimestamp(event.timestamp / 1000, timezone.utc).isoformat().replace("+00:00", "Z")
        return self.created_at or datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")

    def _remove_streaming(self, message_id: str) -> None:
        self._streaming_message_ids = [item for item in self._streaming_message_ids if item != message_id]

    def _matches_conversation(self, event: RunStartedEvent | RunFinishedEvent) -> bool:
        if event.thread_id == self.conversation_id:
            return True
        self._diagnose("conversation_mismatch", event, f"threadId {event.thread_id!r} does not match this conversation")
        return False

    def _diagnose(self, code: str, event: BaseEvent, detail: str) -> None:
        event_type = str(event.type)
        self.diagnostics.append(AdapterDiagnostic(code=code, event_type=event_type, detail=detail))
        LOGGER.info("AG-UI adapter ignored %s: %s", event_type, detail)
