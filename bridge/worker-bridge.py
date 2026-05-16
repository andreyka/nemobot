#!/usr/bin/env python3
import html
import json
import os
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlparse
from urllib.request import Request, urlopen


LISTEN_HOST = os.environ.get("LISTEN_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8080"))
WORKER_GATEWAY_URL = os.environ.get(
    "WORKER_GATEWAY_URL",
    "http://nemoworker.openshell.svc.cluster.local:18789/v1/chat/completions",
)
WORKER_GATEWAY_TOKEN = os.environ["WORKER_GATEWAY_TOKEN"]
DEFAULT_TIMEOUT = int(os.environ.get("WORKER_TIMEOUT_SECONDS", "1800"))
JOB_STATE_DIR = Path(os.environ.get("JOB_STATE_DIR", "/tmp/openclaw-worker-bridge-jobs"))
JOB_STATE_DIR.mkdir(parents=True, exist_ok=True)
JOB_POLL_SECONDS = float(os.environ.get("JOB_POLL_SECONDS", "2"))
JOB_RETENTION_SECONDS = int(os.environ.get("JOB_RETENTION_SECONDS", "86400"))
MAX_LISTED_JOBS = int(os.environ.get("MAX_LISTED_JOBS", "50"))


def now_ts() -> float:
    return time.time()


def prune_jobs() -> None:
    cutoff = now_ts() - JOB_RETENTION_SECONDS
    for path in JOB_STATE_DIR.glob("*.json"):
        try:
            record = json.loads(path.read_text())
        except Exception:
            continue
        finished_at = record.get("finishedAt") or record.get("createdAt") or 0
        if finished_at < cutoff:
            path.unlink(missing_ok=True)


def job_path(job_id: str) -> Path:
    return JOB_STATE_DIR / f"{job_id}.json"


def read_job(job_id: str):
    path = job_path(job_id)
    if not path.exists():
        return None
    return json.loads(path.read_text())


def write_job(record: dict):
    JOB_STATE_DIR.mkdir(parents=True, exist_ok=True)
    path = job_path(record["id"])
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(record, indent=2, sort_keys=True))
    tmp.replace(path)


def list_jobs(limit: int = MAX_LISTED_JOBS):
    items = []
    for path in JOB_STATE_DIR.glob("*.json"):
        try:
            items.append(json.loads(path.read_text()))
        except Exception:
            continue
    items.sort(key=lambda item: item.get("createdAt") or 0, reverse=True)
    return items[:limit]


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
    return json.dumps(content)


def extract_text_response(obj):
    choice = (obj.get("choices") or [{}])[0]
    message = choice.get("message") or {}
    content = flatten_content(message.get("content", "")).strip()
    if content:
        return ("ok", content)

    reasoning = flatten_content(
        message.get("reasoning")
        or message.get("reasoning_content")
        or ""
    ).strip()
    finish_reason = choice.get("finish_reason") or choice.get("stop_reason") or "unknown"
    if reasoning:
        return (
            "reasoning_only",
            f"worker returned no final assistant content (finish_reason={finish_reason}); model produced reasoning-only output",
        )
    return (
        "empty",
        f"worker returned no assistant content (finish_reason={finish_reason})",
    )


def perform_worker_call(agent: str, prompt: str, session_key: str, timeout_seconds: int):
    payload = {
        "model": f"openclaw:{agent}",
        "messages": [
            {
                "role": "user",
                "content": prompt,
            }
        ],
    }
    headers = {
        "Authorization": f"Bearer {WORKER_GATEWAY_TOKEN}",
        "Content-Type": "application/json",
        "x-openclaw-session-key": session_key,
    }
    req = Request(
        WORKER_GATEWAY_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers=headers,
        method="POST",
    )

    try:
        with urlopen(req, timeout=timeout_seconds) as resp:
            raw = resp.read().decode("utf-8")
    except HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        return ("failed", f"gateway error {exc.code}", body)
    except URLError as exc:
        return ("failed", "bridge error", str(exc))

    try:
        obj = json.loads(raw)
    except json.JSONDecodeError:
        return ("failed", "invalid gateway response", raw)

    status, body = extract_text_response(obj)
    if status == "ok":
        return ("succeeded", "ok", body)
    return ("failed", status, body)


def start_async_job(agent: str, prompt: str, session_key: str, timeout_seconds: int):
    prune_jobs()
    record = {
        "id": uuid.uuid4().hex,
        "agent": agent,
        "session": session_key,
        "prompt": prompt,
        "timeoutSeconds": timeout_seconds,
        "status": "queued",
        "detail": "queued",
        "result": "",
        "createdAt": now_ts(),
        "startedAt": None,
        "finishedAt": None,
    }
    write_job(record)

    def runner():
        running = dict(record)
        try:
            running["status"] = "running"
            running["detail"] = "running"
            running["startedAt"] = now_ts()
            write_job(running)

            status, detail, result = perform_worker_call(agent, prompt, session_key, timeout_seconds)
            running["status"] = status
            running["detail"] = detail
            running["result"] = result
            running["finishedAt"] = now_ts()
            write_job(running)
        except Exception as exc:  # pragma: no cover
            running["status"] = "failed"
            running["detail"] = "bridge exception"
            running["result"] = str(exc)
            running["finishedAt"] = now_ts()
            write_job(running)

    threading.Thread(target=runner, daemon=True).start()
    return record


def parse_timeout(raw_value: str, default: int = DEFAULT_TIMEOUT) -> int:
    try:
        return max(1, int(raw_value))
    except (TypeError, ValueError):
        return default


class Handler(BaseHTTPRequestHandler):
    server_version = "openclaw-worker-bridge/1.1"

    def do_GET(self):
        parsed = urlparse(self.path)
        params = parse_qs(parsed.query, keep_blank_values=False)

        if parsed.path == "/healthz":
            self._json(200, {"ok": True, "jobsDir": str(JOB_STATE_DIR)})
            return

        if parsed.path == "/jobs":
            limit = parse_timeout((params.get("limit") or [str(MAX_LISTED_JOBS)])[0], MAX_LISTED_JOBS)
            self._json(200, {"ok": True, "jobs": list_jobs(limit=limit)})
            return

        if parsed.path == "/status":
            job_id = (params.get("id") or [""])[0].strip()
            if not job_id:
                self._json(400, {"ok": False, "error": "missing id"})
                return
            record = read_job(job_id)
            if not record:
                self._json(404, {"ok": False, "error": "job not found", "id": job_id})
                return
            self._json(200, {"ok": True, "job": record})
            return

        if parsed.path == "/wait":
            job_id = (params.get("id") or [""])[0].strip()
            wait_timeout = parse_timeout((params.get("timeout") or [str(DEFAULT_TIMEOUT)])[0], DEFAULT_TIMEOUT)
            deadline = now_ts() + wait_timeout
            if not job_id:
                self._json(400, {"ok": False, "error": "missing id"})
                return
            while True:
                record = read_job(job_id)
                if not record:
                    self._json(404, {"ok": False, "error": "job not found", "id": job_id})
                    return
                if record["status"] in {"succeeded", "failed"}:
                    code = 200 if record["status"] == "succeeded" else 502
                    self._json(code, {"ok": record["status"] == "succeeded", "job": record})
                    return
                if now_ts() >= deadline:
                    self._json(202, {"ok": False, "job": record, "waiting": True})
                    return
                time.sleep(JOB_POLL_SECONDS)

        if parsed.path not in {"/run", "/submit"}:
            self._text(404, "not found")
            return

        agent = (params.get("agent") or ["researcher"])[0]
        prompt = (params.get("q") or [""])[0].strip()
        session_key = (params.get("session") or [f"bridge:{agent}"])[0]
        timeout_seconds = parse_timeout((params.get("timeout") or [str(DEFAULT_TIMEOUT)])[0], DEFAULT_TIMEOUT)

        if not prompt:
            self._text(400, "missing q")
            return

        if parsed.path == "/submit":
            record = start_async_job(agent, prompt, session_key, timeout_seconds)
            self._json(
                202,
                {
                    "ok": True,
                    "job": record,
                    "statusUrl": f"/status?id={record['id']}",
                    "waitUrl": f"/wait?id={record['id']}&timeout={timeout_seconds}",
                },
            )
            return

        status, detail, body = perform_worker_call(agent, prompt, session_key, timeout_seconds)
        if status == "succeeded":
            self._html(200, agent, prompt, session_key, "ok", body)
            return
        self._html(502, agent, prompt, session_key, detail, body)

    def log_message(self, format, *args):
        return

    def _text(self, status, text):
        payload = text.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _json(self, status, obj):
        payload = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _html(self, status, agent, prompt, session_key, result, body):
        escaped_prompt = html.escape(prompt)
        escaped_body = html.escape(body)
        escaped_agent = html.escape(agent)
        escaped_session = html.escape(session_key)
        html_doc = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>OpenClaw Worker Bridge</title>
  <style>
    body {{ font-family: ui-monospace, SFMono-Regular, Menlo, monospace; margin: 2rem; line-height: 1.5; }}
    h1 {{ font-size: 1.1rem; }}
    .meta {{ color: #555; margin-bottom: 1rem; }}
    pre {{ white-space: pre-wrap; background: #f6f6f6; padding: 1rem; border-radius: 8px; }}
  </style>
</head>
<body>
  <h1>OpenClaw Worker Bridge</h1>
  <div class="meta">agent={escaped_agent} session={escaped_session} status={html.escape(result)}</div>
  <p><strong>Prompt</strong></p>
  <pre>{escaped_prompt}</pre>
  <p><strong>Result</strong></p>
  <pre>{escaped_body}</pre>
</body>
</html>
"""
        payload = html_doc.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


if __name__ == "__main__":
    prune_jobs()
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    server.serve_forever()
