#!/usr/bin/env python3
import json
import os
import time
from typing import Iterable

import requests
from flask import Flask, Response, jsonify, request, stream_with_context


UPSTREAM_BASE = "https://api.anthropic.com/v1"
TIMEOUT = 180
HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}

app = Flask(__name__)


def debug_enabled() -> bool:
    return os.environ.get("OPENCLAW_PROXY_DEBUG", "").strip().lower() in {"1", "true", "yes", "on"}


def emit_debug(event: str, **fields) -> None:
    if not debug_enabled():
        return
    record = {"event": event, **fields}
    print(json.dumps(record, ensure_ascii=False), flush=True)


def configured_model() -> str:
    return os.environ.get("ANTHROPIC_MODEL", "claude-opus-4-7").strip()


def configured_model_name() -> str:
    return os.environ.get("ANTHROPIC_MODEL_NAME", configured_model()).strip()


def auth_headers() -> dict[str, str]:
    api_key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
    if not api_key:
        raise RuntimeError("ANTHROPIC_API_KEY is not configured")
    return {
        "Authorization": f"Bearer {api_key}",
        "x-api-key": api_key,
        "anthropic-version": "2023-06-01",
    }


def passthrough_headers() -> dict[str, str]:
    headers = {}
    for key, value in request.headers.items():
        lower = key.lower()
        if lower in HOP_HEADERS or lower in {"host", "authorization"}:
            continue
        headers[key] = value
    headers.update(auth_headers())
    return headers


def response_headers(upstream: requests.Response) -> dict[str, str]:
    return {
        key: value
        for key, value in upstream.headers.items()
        if key.lower() not in HOP_HEADERS
    }


def flatten_content(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for item in content:
            if isinstance(item, dict):
                text = item.get("text")
                if text:
                    parts.append(text)
        return "\n".join(parts)
    if content is None:
        return ""
    return str(content)


def normalize_chat_payload(payload: dict) -> dict:
    normalized = dict(payload)

    messages = []
    for message in normalized.get("messages", []):
        if not isinstance(message, dict):
            messages.append(message)
            continue
        msg = dict(message)
        if "content" in msg:
            msg["content"] = flatten_content(msg.get("content"))
        messages.append(msg)
    if messages:
        normalized["messages"] = messages

    tools = []
    for tool in normalized.get("tools", []):
        if not isinstance(tool, dict):
            tools.append(tool)
            continue
        cleaned_tool = dict(tool)
        fn = cleaned_tool.get("function")
        if isinstance(fn, dict):
            fn = dict(fn)
            fn.pop("strict", None)
            cleaned_tool["function"] = fn
        tools.append(cleaned_tool)
    if tools:
        normalized["tools"] = tools

    max_completion_tokens = normalized.pop("max_completion_tokens", None)
    if max_completion_tokens is not None and "max_tokens" not in normalized:
        normalized["max_tokens"] = max_completion_tokens

    normalized.pop("store", None)
    normalized.pop("stream_options", None)
    normalized.pop("reasoning", None)
    normalized.pop("reasoning_effort", None)
    return normalized


def sse_chunk(payload: dict) -> bytes:
    return f"data: {json.dumps(payload, ensure_ascii=False, separators=(',', ':'))}\n\n".encode("utf-8")


def synthesize_stream(body: bytes) -> Iterable[bytes]:
    completion = json.loads(body.decode("utf-8"))
    choices = completion.get("choices") or []
    choice = choices[0] if choices else {}
    message = choice.get("message") or {}
    tool_calls = message.get("tool_calls") or []
    finish_reason = choice.get("finish_reason") or "stop"
    base = {
        "id": completion.get("id") or f"chatcmpl-proxy-{int(time.time() * 1000)}",
        "created": completion.get("created") or int(time.time()),
        "model": completion.get("model") or configured_model(),
        "object": "chat.completion.chunk",
    }

    yield sse_chunk({
        **base,
        "choices": [{"index": 0, "delta": {"role": message.get("role", "assistant")}}],
    })

    content = flatten_content(message.get("content"))
    if content:
        yield sse_chunk({
            **base,
            "choices": [{"index": 0, "delta": {"content": content}}],
        })

    for index, tool_call in enumerate(tool_calls):
        function = tool_call.get("function") or {}
        delta = {
            "tool_calls": [
                {
                    "index": index,
                    "id": tool_call.get("id"),
                    "type": tool_call.get("type", "function"),
                    "function": {
                        "name": function.get("name"),
                        "arguments": function.get("arguments", ""),
                    },
                }
            ]
        }
        yield sse_chunk({
            **base,
            "choices": [{"index": 0, "delta": delta}],
        })

    yield sse_chunk({
        **base,
        "choices": [{"index": 0, "delta": {}, "finish_reason": finish_reason}],
    })
    yield b"data: [DONE]\n\n"


def upstream_request(method: str, path: str, *, stream: bool = False, body: bytes | None = None) -> requests.Response:
    if body is None and method in {"POST", "PUT", "PATCH"}:
        body = request.get_data()
    return requests.request(
        method=method,
        url=f"{UPSTREAM_BASE}{path}",
        headers=passthrough_headers(),
        params=request.args,
        data=body,
        timeout=TIMEOUT,
        stream=stream,
    )


@app.get("/healthz")
def healthz():
    return jsonify({"ok": True, "model": configured_model()})


@app.get("/v1/models")
def models():
    model_id = configured_model()
    body = json.dumps(
        {
            "object": "list",
            "data": [
                {
                    "id": model_id,
                    "object": "model",
                    "owned_by": "anthropic",
                    "name": configured_model_name(),
                }
            ],
        }
    ).encode("utf-8")
    return Response(body, status=200, headers={"Content-Type": "application/json"})


@app.post("/v1/chat/completions")
def chat_completions():
    payload = request.get_json(silent=True) or {}
    wants_stream = bool(payload.get("stream"))
    normalized = normalize_chat_payload(payload)
    upstream_payload = dict(normalized)
    upstream_payload["stream"] = False
    emit_debug(
        "chat_request",
        path=request.path,
        model=normalized.get("model"),
        stream=wants_stream,
        tool_count=len(normalized.get("tools", []) or []),
        message_count=len(normalized.get("messages", []) or []),
        max_tokens=normalized.get("max_tokens"),
        keys=sorted(normalized.keys()),
    )
    upstream = upstream_request(
        "POST",
        "/chat/completions",
        stream=False,
        body=json.dumps(upstream_payload).encode("utf-8"),
    )
    headers = response_headers(upstream)
    if wants_stream:
        body = upstream.content
        preview = body.decode("utf-8", errors="replace")[:4000]
        emit_debug(
            "chat_synth_stream_source",
            path=request.path,
            model=normalized.get("model"),
            status=upstream.status_code,
            content_type=upstream.headers.get("Content-Type"),
            preview=preview,
        )
        if upstream.status_code >= 400:
            upstream.close()
            return Response(body, status=upstream.status_code, headers=headers)

        synth_headers = {
            "Content-Type": "text/event-stream; charset=utf-8",
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
        }

        def generate() -> Iterable[bytes]:
            try:
                yield from synthesize_stream(body)
            finally:
                emit_debug(
                    "chat_synth_stream_response",
                    path=request.path,
                    model=normalized.get("model"),
                    status=upstream.status_code,
                    content_type=upstream.headers.get("Content-Type"),
                    preview=preview,
                )
                upstream.close()

        return Response(
            stream_with_context(generate()),
            status=upstream.status_code,
            headers=synth_headers,
        )

    body = upstream.content
    preview = body.decode("utf-8", errors="replace")[:4000]
    emit_debug(
        "chat_response",
        path=request.path,
        model=normalized.get("model"),
        status=upstream.status_code,
        content_type=upstream.headers.get("Content-Type"),
        preview=preview,
    )

    return Response(
        body,
        status=upstream.status_code,
        headers=headers,
    )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=9005)
