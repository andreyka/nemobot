#!/usr/bin/env python3
import json
import os
from typing import Iterable

import requests
from flask import Flask, Response, jsonify, request, stream_with_context


UPSTREAM_BASE = "https://integrate.api.nvidia.com"
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


def auth_headers() -> dict[str, str]:
    api_key = os.environ.get("NVIDIA_API_KEY", "").strip()
    if not api_key:
        raise RuntimeError("NVIDIA_API_KEY is not configured")
    return {"Authorization": f"Bearer {api_key}"}


def passthrough_headers() -> dict[str, str]:
    headers = {}
    for key, value in request.headers.items():
        lower = key.lower()
        if lower in HOP_HEADERS or lower == "host":
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

    normalized.pop("reasoning", None)
    normalized.pop("reasoning_effort", None)
    return normalized


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
    return jsonify({"ok": True})


@app.get("/v1/models")
def models():
    upstream = upstream_request("GET", "/v1/models")
    return Response(
        upstream.content,
        status=upstream.status_code,
        headers=response_headers(upstream),
    )


@app.post("/v1/chat/completions")
def chat_completions():
    payload = request.get_json(silent=True) or {}
    wants_stream = bool(payload.get("stream"))
    upstream = upstream_request(
        "POST",
        "/v1/chat/completions",
        stream=wants_stream,
        body=json.dumps(normalize_chat_payload(payload)).encode("utf-8"),
    )
    headers = response_headers(upstream)
    if wants_stream:
        def generate() -> Iterable[bytes]:
            try:
                for chunk in upstream.iter_content(chunk_size=8192):
                    if chunk:
                        yield chunk
            finally:
                upstream.close()

        return Response(
            stream_with_context(generate()),
            status=upstream.status_code,
            headers=headers,
        )

    return Response(
        upstream.content,
        status=upstream.status_code,
        headers=headers,
    )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=9002)
