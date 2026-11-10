#!/usr/bin/env python3
"""Mock gateway for the live tests. It speaks both wire formats:

  Anthropic Messages   POST /v1/messages          GET /v1/models?limit=1000
  OpenAI-compatible    POST /v1/chat/completions  GET /v1/models

The first chat call streams a tool call and the follow-up streams text. Anthropic requests are
checked against rules the real API enforces; a violation is answered with HTTP 400 and the reason,
so the test that sent it fails with a useful message.

Usage: python3 mock_server.py 8765
       TERMAI_TEST_BASEURL=http://127.0.0.1:8765 swift test
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def sse(payload, event=None):
    head = "event: %s\n" % event if event else ""
    return (head + "data: " + json.dumps(payload, ensure_ascii=False) + "\n\n").encode()


def check_anthropic(headers, body):
    """Returns why the real API would reject this request, or None."""
    if headers.get("anthropic-version") != "2023-06-01":
        return "anthropic-version header is missing"
    if not isinstance(body.get("max_tokens"), int):
        return "max_tokens is required"
    messages = body.get("messages") or []
    if not messages or messages[0]["role"] != "user":
        return "the first message must be a user turn"
    pending = []
    for position, message in enumerate(messages):
        if position and message["role"] == messages[position - 1]["role"]:
            return "user and assistant turns must alternate"
        blocks = message["content"]
        if not isinstance(blocks, list) or not blocks:
            return "content must be a non-empty list of blocks"
        if message["role"] == "user":
            results = [b["tool_use_id"] for b in blocks if b["type"] == "tool_result"]
            if sorted(results) != sorted(pending):
                return "tool_use ids %s were answered with %s" % (pending, results)
            seen_other = False
            for block in blocks:
                if block["type"] != "tool_result":
                    seen_other = True
                elif seen_other:
                    return "tool_result blocks must come first in a user turn"
            pending = []
        else:
            if pending:
                return "tool_use was not followed by tool_result"
            pending = [b["id"] for b in blocks if b["type"] == "tool_use"]
            for block in blocks:
                if block["type"] == "text" and not block["text"].strip():
                    return "text blocks must not be empty"
                if block["type"] == "tool_use" and not isinstance(block.get("input"), dict):
                    return "tool_use input must be an object"
    if pending:
        return "the conversation ends with an unanswered tool_use"
    if any("input_schema" not in tool for tool in body.get("tools", [])):
        return "tools need input_schema"
    return None


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _json(self, status, payload):
        raw = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _reject(self, reason):
        self._json(400, {"type": "error", "error": {"type": "invalid_request_error", "message": reason}})

    def _authorized(self):
        if self.headers.get("Authorization") == "Bearer test-key" or self.headers.get("x-api-key") == "test-key":
            return True
        self._json(401, {"type": "error", "error": {"type": "authentication_error", "message": "bad key"}})
        return False

    def _stream(self, raw):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        # Deliberately awkward chunking: split mid-line and mid-character.
        for start in range(0, len(raw), 7):
            self.wfile.write(raw[start:start + 7])
            self.wfile.flush()
            time.sleep(0.001)

    def do_GET(self):
        if not self._authorized():
            return
        if self.path == "/v1/models?limit=1000":
            if self.headers.get("anthropic-version") != "2023-06-01":
                return self._reject("anthropic-version header is missing")
            self._json(200, {"data": [{"id": "claude-mock-1", "display_name": "Claude Mock 1"}, {"id": "claude-mock-2"}]})
        elif self.path == "/v1/models":
            self._json(200, {"data": [{"id": "mock-b"}, {"id": "mock-a"}]})
        else:
            self._json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        if not self._authorized():
            return
        if self.path == "/v1/messages":
            self._anthropic(body)
        elif self.path == "/v1/chat/completions":
            self._openai(body)
        else:
            self._json(404, {"error": {"message": "not found"}})

    def _anthropic(self, body):
        problem = check_anthropic(self.headers, body)
        if problem:
            return self._reject(problem)
        if body["model"] == "overloaded":
            return self._json(529, {"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}})
        messages = body["messages"]

        def delta(index, payload):
            return sse({"type": "content_block_delta", "index": index, "delta": payload}, "content_block_delta")

        def start(index, block):
            return sse({"type": "content_block_start", "index": index, "content_block": block}, "content_block_start")

        def stop(index):
            return sse({"type": "content_block_stop", "index": index}, "content_block_stop")

        events = [sse({"type": "message_start", "message": {
            "id": "msg_1", "type": "message", "role": "assistant", "model": body["model"], "content": [],
            "stop_reason": None,
            "usage": {"input_tokens": 20, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 100, "output_tokens": 1},
        }}, "message_start")]
        answered = any(b["type"] == "tool_result" for m in messages if m["role"] == "user" for b in m["content"])
        if not answered:
            events += [
                start(0, {"type": "thinking", "thinking": "", "signature": ""}),
                delta(0, {"type": "thinking_delta", "thinking": "Let me "}),
                delta(0, {"type": "thinking_delta", "thinking": "check."}),
                delta(0, {"type": "signature_delta", "signature": "sig-123"}),
                stop(0),
                sse({"type": "ping"}, "ping"),
                start(1, {"type": "text", "text": ""}),
                delta(1, {"type": "text_delta", "text": "Checking "}),
                delta(1, {"type": "text_delta", "text": "héllo ✓"}),
                stop(1),
                start(2, {"type": "tool_use", "id": "toolu_1", "name": "Bash", "input": {}}),
                delta(2, {"type": "input_json_delta", "partial_json": '{"comm'}),
                delta(2, {"type": "input_json_delta", "partial_json": 'and":"echo hi"}'}),
                stop(2),
                sse({"type": "message_delta", "delta": {"stop_reason": "tool_use", "stop_sequence": None},
                     "usage": {"output_tokens": 30}}, "message_delta"),
            ]
        else:
            # The second round must return the reasoning block untouched and keep the request shape.
            assistant = next(m for m in messages if m["role"] == "assistant")
            thinking = [b for b in assistant["content"] if b["type"] == "thinking"]
            if not thinking or thinking[0].get("thinking") != "Let me check." or thinking[0].get("signature") != "sig-123":
                return self._reject("the thinking block was not returned unchanged")
            if body.get("output_config") != {"effort": "high"}:
                return self._reject("output_config.effort was not sent")
            if (body.get("system") or [{}])[0].get("cache_control") != {"type": "ephemeral"}:
                return self._reject("the system prompt has no cache breakpoint")
            if messages[-1]["content"][-1].get("cache_control") != {"type": "ephemeral"}:
                return self._reject("the newest block has no cache breakpoint")
            events += [
                start(0, {"type": "text", "text": ""}),
                delta(0, {"type": "text_delta", "text": "done"}),
                stop(0),
                sse({"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                     "usage": {"output_tokens": 5}}, "message_delta"),
            ]
        events.append(sse({"type": "message_stop"}, "message_stop"))
        self._stream(b"".join(events))

    def _openai(self, body):
        answered = any(m["role"] == "tool" for m in body["messages"])
        if answered:
            raw = b"".join(sse({"choices": [{"delta": {"content": text}}]}) for text in ["héllo ", "✓ done"])
            raw += sse({"choices": [{"delta": {}, "finish_reason": "stop"}]})
            raw += sse({"choices": [], "usage": {"prompt_tokens": 9, "completion_tokens": 4}})
        else:
            deltas = [
                {"tool_calls": [{"index": 0, "id": "call_1", "function": {"name": "Bash", "arguments": ""}}]},
                {"tool_calls": [{"index": 0, "function": {"arguments": '{"command":'}}]},
                {"tool_calls": [{"index": 0, "function": {"arguments": '"echo hi"}'}}]},
            ]
            raw = b"".join(sse({"choices": [{"delta": d}]}) for d in deltas)
            raw += sse({"choices": [{"delta": {}, "finish_reason": "tool_calls"}]})
        self._stream(raw + b"data: [DONE]\n\n")


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
