#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


DEFAULT_BASE_URL = os.environ.get("OPENCLAW_MEMORY_URL", "http://host.openshell.internal:9004")


def request_json(method: str, path: str, payload=None):
    url = urllib.parse.urljoin(DEFAULT_BASE_URL.rstrip("/") + "/", path.lstrip("/"))
    data = None
    headers = {"Accept": "application/json"}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read().decode("utf-8")
            return json.loads(body) if body else {"ok": True}
    except urllib.error.HTTPError as exc:
        details = exc.read().decode("utf-8", errors="replace")
        raise SystemExit(f"memory service {exc.code}: {details}") from exc
    except urllib.error.URLError as exc:
        raise SystemExit(f"memory service unreachable: {exc.reason}") from exc


def emit(obj):
    json.dump(obj, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")


def summarize_file(path: Path):
    text = path.read_text(encoding="utf-8", errors="replace")
    stripped = text.strip()
    if not stripped:
        summary = f"stored file {path.name} ({path.stat().st_size} bytes)"
    else:
        first_line = next((line.strip() for line in stripped.splitlines() if line.strip()), "")
        summary = first_line[:160]
    digest = hashlib.sha256(text.encode("utf-8", errors="replace")).hexdigest()
    return text, summary, digest


def cmd_store_note(args):
    body = args.body or ""
    if args.body_file:
        body = Path(args.body_file).read_text(encoding="utf-8", errors="replace")
    payload = {
        "agent": args.agent,
        "task": args.task,
        "session_key": args.session,
        "kind": args.kind,
        "title": args.title,
        "summary": args.summary,
        "body": body,
        "source_url": args.source_url,
        "tags": args.tags,
        "pinned": args.pinned,
        "metadata": {},
    }
    if args.metadata_json:
        payload["metadata"] = json.loads(args.metadata_json)
    result = request_json("POST", "/v1/documents", payload)
    emit(result)


def cmd_store_file(args):
    path = Path(args.path)
    if not path.is_file():
        raise SystemExit(f"file not found: {path}")
    body, inferred_summary, digest = summarize_file(path)
    payload = {
        "agent": args.agent,
        "task": args.task,
        "session_key": args.session,
        "kind": args.kind,
        "title": args.title or path.name,
        "summary": args.summary or inferred_summary,
        "body": body,
        "source_url": args.source_url,
        "tags": args.tags,
        "pinned": args.pinned,
        "metadata": {
            "path": str(path),
            "size": path.stat().st_size,
            "sha256": digest,
        },
    }
    result = request_json("POST", "/v1/documents", payload)
    emit(result)


def cmd_search(args):
    payload = {
        "q": args.query,
        "limit": args.limit,
        "agent": args.agent,
        "task": args.task,
    }
    result = request_json("POST", "/v1/search", payload)
    emit(result)


def cmd_get(args):
    result = request_json("GET", f"/documents/{args.id}?format=json")
    emit(result)


def build_parser():
    parser = argparse.ArgumentParser(prog="openclaw-memory")
    sub = parser.add_subparsers(dest="cmd", required=True)

    note = sub.add_parser("store-note")
    note.add_argument("--agent", required=True)
    note.add_argument("--task", default="")
    note.add_argument("--session", default="")
    note.add_argument("--kind", default="note")
    note.add_argument("--title", required=True)
    note.add_argument("--summary", required=True)
    note.add_argument("--body", default="")
    note.add_argument("--body-file")
    note.add_argument("--source-url", default="")
    note.add_argument("--tags", default="")
    note.add_argument("--pinned", action="store_true")
    note.add_argument("--metadata-json")
    note.set_defaults(func=cmd_store_note)

    file_cmd = sub.add_parser("store-file")
    file_cmd.add_argument("--agent", required=True)
    file_cmd.add_argument("--task", default="")
    file_cmd.add_argument("--session", default="")
    file_cmd.add_argument("--kind", default="file")
    file_cmd.add_argument("--path", required=True)
    file_cmd.add_argument("--title")
    file_cmd.add_argument("--summary")
    file_cmd.add_argument("--source-url", default="")
    file_cmd.add_argument("--tags", default="")
    file_cmd.add_argument("--pinned", action="store_true")
    file_cmd.set_defaults(func=cmd_store_file)

    search = sub.add_parser("search")
    search.add_argument("--query", default="")
    search.add_argument("--limit", type=int, default=10)
    search.add_argument("--agent", default="")
    search.add_argument("--task", default="")
    search.set_defaults(func=cmd_search)

    get = sub.add_parser("get")
    get.add_argument("--id", type=int, required=True)
    get.set_defaults(func=cmd_get)

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
