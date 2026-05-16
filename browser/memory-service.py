#!/usr/bin/env python3
import html
import json
import os
import sys
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import psycopg
from psycopg.rows import dict_row


LISTEN_HOST = os.environ.get("MEMORY_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("MEMORY_PORT", "9004"))
POSTGRES_HOST = os.environ.get("POSTGRES_HOST", "openclaw-memory-db")
POSTGRES_PORT = int(os.environ.get("POSTGRES_PORT", "5432"))
POSTGRES_USER = os.environ.get("POSTGRES_USER", "openclaw_memory")
POSTGRES_PASSWORD = os.environ["POSTGRES_PASSWORD"]
POSTGRES_DB = os.environ.get("POSTGRES_DB", "openclaw_memory")
DEFAULT_LIMIT = int(os.environ.get("MEMORY_DEFAULT_LIMIT", "10"))
CONNECT_RETRIES = int(os.environ.get("MEMORY_CONNECT_RETRIES", "60"))
CONNECT_RETRY_SLEEP = float(os.environ.get("MEMORY_CONNECT_RETRY_SLEEP", "1.0"))


def connect():
    return psycopg.connect(
        host=POSTGRES_HOST,
        port=POSTGRES_PORT,
        user=POSTGRES_USER,
        password=POSTGRES_PASSWORD,
        dbname=POSTGRES_DB,
        autocommit=True,
        row_factory=dict_row,
    )


def wait_for_db():
    last_error = None
    for _ in range(CONNECT_RETRIES):
        try:
            conn = connect()
            ensure_schema(conn)
            conn.close()
            return
        except Exception as exc:  # pragma: no cover
            last_error = exc
            time.sleep(CONNECT_RETRY_SLEEP)
    raise RuntimeError(f"failed to connect to postgres: {last_error}")


def ensure_schema(conn):
    with conn.cursor() as cur:
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS documents (
              id BIGSERIAL PRIMARY KEY,
              created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
              updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
              agent TEXT NOT NULL DEFAULT 'unknown',
              task TEXT,
              session_key TEXT,
              kind TEXT NOT NULL DEFAULT 'note',
              title TEXT NOT NULL,
              summary TEXT NOT NULL,
              body TEXT NOT NULL DEFAULT '',
              source_url TEXT,
              tags TEXT[] NOT NULL DEFAULT '{}',
              pinned BOOLEAN NOT NULL DEFAULT FALSE,
              metadata JSONB NOT NULL DEFAULT '{}'::jsonb
            )
            """
        )
        cur.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_documents_updated_at
              ON documents (updated_at DESC)
            """
        )
        cur.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_documents_task
              ON documents (task)
            """
        )
        cur.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_documents_agent
              ON documents (agent)
            """
        )
        cur.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_documents_tags
              ON documents USING GIN (tags)
            """
        )
        cur.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_documents_search
              ON documents
              USING GIN (
                to_tsvector(
                  'english',
                  coalesce(title, '') || ' ' || coalesce(summary, '') || ' ' || coalesce(body, '')
                )
              )
            """
        )


def split_tags(raw_tags):
    if isinstance(raw_tags, list):
        return [str(item).strip() for item in raw_tags if str(item).strip()]
    if not raw_tags:
        return []
    return [item.strip() for item in str(raw_tags).split(",") if item.strip()]


def insert_document(payload):
    title = str(payload.get("title", "")).strip()
    summary = str(payload.get("summary", "")).strip()
    if not title or not summary:
        raise ValueError("title and summary are required")

    body = str(payload.get("body", "")).strip()
    source_url = str(payload.get("source_url", payload.get("source", ""))).strip() or None
    task = str(payload.get("task", "")).strip() or None
    session_key = str(payload.get("session_key", payload.get("session", ""))).strip() or None
    kind = str(payload.get("kind", "note")).strip() or "note"
    agent = str(payload.get("agent", "unknown")).strip() or "unknown"
    pinned = bool(payload.get("pinned", False))
    tags = split_tags(payload.get("tags"))
    metadata = payload.get("metadata") or {}
    if not isinstance(metadata, dict):
        metadata = {"raw": metadata}

    with connect() as conn, conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO documents (
              agent, task, session_key, kind, title, summary, body, source_url, tags, pinned, metadata
            )
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s::jsonb)
            RETURNING id, created_at, updated_at
            """,
            [
                agent,
                task,
                session_key,
                kind,
                title,
                summary,
                body,
                source_url,
                tags,
                pinned,
                json.dumps(metadata),
            ],
        )
        row = cur.fetchone()
    return {
        "ok": True,
        "id": row["id"],
        "created_at": row["created_at"].isoformat(),
        "updated_at": row["updated_at"].isoformat(),
    }


def search_documents(query, limit=DEFAULT_LIMIT, agent=None, task=None):
    limit = max(1, min(int(limit), 50))
    query = (query or "").strip()
    agent = (agent or "").strip()
    task = (task or "").strip()

    where = []
    rank_params = []
    params = []
    rank_sql = "0.0"

    if query:
        vector = (
            "to_tsvector('english', coalesce(title, '') || ' ' || coalesce(summary, '') || ' ' || coalesce(body, ''))"
        )
        tsq = "websearch_to_tsquery('english', %s)"
        where.append(f"({vector} @@ {tsq} OR title ILIKE %s OR summary ILIKE %s OR body ILIKE %s)")
        like = f"%{query}%"
        rank_params.append(query)
        params.extend([query, like, like, like])
        rank_sql = f"ts_rank_cd({vector}, {tsq})"

    if agent:
        where.append("agent = %s")
        params.append(agent)
    if task:
        where.append("task = %s")
        params.append(task)

    where_sql = "WHERE " + " AND ".join(where) if where else ""
    sql = f"""
        SELECT
          id,
          created_at,
          updated_at,
          agent,
          task,
          session_key,
          kind,
          title,
          summary,
          body,
          source_url,
          tags,
          pinned,
          metadata,
          {rank_sql} AS rank
        FROM documents
        {where_sql}
        ORDER BY pinned DESC, rank DESC NULLS LAST, updated_at DESC
        LIMIT %s
    """
    params.append(limit)

    with connect() as conn, conn.cursor() as cur:
        cur.execute(sql, rank_params + params)
        rows = cur.fetchall()
    return [normalize_row(row) for row in rows]


def get_document(doc_id):
    with connect() as conn, conn.cursor() as cur:
        cur.execute(
            """
            SELECT
              id,
              created_at,
              updated_at,
              agent,
              task,
              session_key,
              kind,
              title,
              summary,
              body,
              source_url,
              tags,
              pinned,
              metadata
            FROM documents
            WHERE id = %s
            """,
            [doc_id],
        )
        row = cur.fetchone()
    return normalize_row(row) if row else None


def normalize_row(row):
    if not row:
        return None
    normalized = dict(row)
    for key in ("created_at", "updated_at"):
        if isinstance(normalized.get(key), datetime):
            normalized[key] = normalized[key].isoformat()
    if "rank" in normalized and normalized["rank"] is not None:
        normalized["rank"] = float(normalized["rank"])
    return normalized


def wants_json(handler):
    parsed = urlparse(handler.path)
    params = parse_qs(parsed.query, keep_blank_values=False)
    fmt = (params.get("format") or [""])[0].strip().lower()
    if fmt == "json":
        return True
    return "application/json" in handler.headers.get("Accept", "")


def html_page(title, body):
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{html.escape(title)}</title>
  <style>
    body {{ font-family: ui-sans-serif, system-ui, sans-serif; margin: 2rem auto; max-width: 960px; line-height: 1.5; color: #111; }}
    h1, h2 {{ line-height: 1.2; }}
    .meta {{ color: #555; font-size: 0.95rem; }}
    .doc {{ border: 1px solid #ddd; border-radius: 10px; padding: 1rem; margin: 1rem 0; }}
    pre {{ white-space: pre-wrap; background: #f6f6f6; padding: 1rem; border-radius: 8px; overflow-x: auto; }}
    code {{ background: #f6f6f6; padding: 0.1rem 0.25rem; border-radius: 4px; }}
    a {{ color: #0b57d0; }}
  </style>
</head>
<body>
{body}
</body>
</html>
"""


def render_home():
    body = """
<h1>OpenClaw Memory Service</h1>
<p class="meta">Durable research memory for long-running technical work.</p>
<ul>
  <li><code>/healthz</code></li>
  <li><code>/search?q=firecracker</code></li>
  <li><code>/store?agent=researcher&title=...&summary=...</code></li>
  <li><code>POST /v1/documents</code> for richer writes</li>
</ul>
"""
    return html_page("OpenClaw Memory Service", body)


def render_search(query, items):
    blocks = []
    for item in items:
        tags = ", ".join(item.get("tags") or [])
        source = item.get("source_url")
        source_html = f'<div><a href="{html.escape(source)}">{html.escape(source)}</a></div>' if source else ""
        blocks.append(
            f"""
<div class="doc">
  <h2><a href="/documents/{item['id']}">{html.escape(item['title'])}</a></h2>
  <div class="meta">
    id={item['id']} agent={html.escape(item.get('agent') or 'unknown')} kind={html.escape(item.get('kind') or 'note')}
    task={html.escape(item.get('task') or '-')}
    updated={html.escape(item.get('updated_at') or '-')}
  </div>
  <p>{html.escape(item.get('summary') or '')}</p>
  {source_html}
  <div class="meta">tags={html.escape(tags or '-')}</div>
</div>
"""
        )
    if not blocks:
        blocks.append("<p>No results.</p>")
    return html_page(
        "Memory Search",
        f"<h1>Memory Search</h1><p class=\"meta\">query={html.escape(query or '(recent)')}</p>{''.join(blocks)}",
    )


def render_document(item):
    if not item:
        return html_page("Document Not Found", "<h1>Document Not Found</h1>"), 404
    source = item.get("source_url")
    source_html = f'<p><a href="{html.escape(source)}">{html.escape(source)}</a></p>' if source else ""
    metadata = html.escape(json.dumps(item.get("metadata") or {}, indent=2, sort_keys=True))
    body = f"""
<h1>{html.escape(item['title'])}</h1>
<p class="meta">
  id={item['id']} agent={html.escape(item.get('agent') or 'unknown')} kind={html.escape(item.get('kind') or 'note')}
  task={html.escape(item.get('task') or '-')}
  session={html.escape(item.get('session_key') or '-')}
</p>
<p>{html.escape(item.get('summary') or '')}</p>
{source_html}
<h2>Body</h2>
<pre>{html.escape(item.get('body') or '')}</pre>
<h2>Metadata</h2>
<pre>{metadata}</pre>
"""
    return html_page(item["title"], body), 200


def render_store_result(result, payload):
    tag_text = html.escape(",".join(split_tags(payload.get("tags"))))
    source = str(payload.get("source_url", payload.get("source", ""))).strip()
    source_html = f'<p><a href="{html.escape(source)}">{html.escape(source)}</a></p>' if source else ""
    body = f"""
<h1>Memory Stored</h1>
<p class="meta">id={result['id']} created_at={html.escape(result['created_at'])}</p>
<p><strong>{html.escape(str(payload.get('title', '')))}</strong></p>
<p>{html.escape(str(payload.get('summary', '')))}</p>
{source_html}
<div class="meta">agent={html.escape(str(payload.get('agent', 'unknown')))} task={html.escape(str(payload.get('task', '')))} tags={tag_text or '-'}</div>
"""
    return html_page("Memory Stored", body)


class Handler(BaseHTTPRequestHandler):
    server_version = "openclaw-memory-service/1.0"

    def do_OPTIONS(self):
        self.send_response(204)
        self._set_common_headers("text/plain; charset=utf-8")
        self.end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)
        params = parse_qs(parsed.query, keep_blank_values=False)

        if parsed.path == "/healthz":
            self._json(200, {"ok": True})
            return
        if parsed.path == "/":
            self._html(200, render_home())
            return
        if parsed.path == "/search":
            query = (params.get("q") or [""])[0]
            limit = (params.get("limit") or [str(DEFAULT_LIMIT)])[0]
            agent = (params.get("agent") or [""])[0]
            task = (params.get("task") or [""])[0]
            rows = search_documents(query, limit=limit, agent=agent, task=task)
            if wants_json(self):
                self._json(200, {"ok": True, "items": rows})
            else:
                self._html(200, render_search(query, rows))
            return
        if parsed.path.startswith("/documents/"):
            doc_id = parsed.path.rsplit("/", 1)[-1]
            if not doc_id.isdigit():
                self._text(400, "invalid document id")
                return
            item = get_document(int(doc_id))
            if wants_json(self):
                if item is None:
                    self._json(404, {"ok": False, "error": "not_found"})
                else:
                    self._json(200, {"ok": True, "item": item})
            else:
                page, status = render_document(item)
                self._html(status, page)
            return
        if parsed.path == "/store":
            payload = {
                "agent": (params.get("agent") or ["unknown"])[0],
                "task": (params.get("task") or [""])[0],
                "session": (params.get("session") or [""])[0],
                "kind": (params.get("kind") or ["note"])[0],
                "title": (params.get("title") or [""])[0],
                "summary": (params.get("summary") or [""])[0],
                "body": (params.get("body") or [""])[0],
                "source": (params.get("source") or [""])[0],
                "tags": (params.get("tags") or [""])[0],
                "pinned": (params.get("pinned") or ["false"])[0].lower() in ("1", "true", "yes"),
            }
            try:
                result = insert_document(payload)
            except ValueError as exc:
                if wants_json(self):
                    self._json(400, {"ok": False, "error": str(exc)})
                else:
                    self._html(400, html_page("Store Failed", f"<h1>Store Failed</h1><p>{html.escape(str(exc))}</p>"))
                return
            if wants_json(self):
                self._json(200, result)
            else:
                self._html(200, render_store_result(result, payload))
            return
        self._text(404, "not found")

    def do_POST(self):
        parsed = urlparse(self.path)
        body = self.rfile.read(int(self.headers.get("Content-Length", "0") or "0"))
        try:
            payload = json.loads(body.decode("utf-8") or "{}")
        except json.JSONDecodeError:
            self._json(400, {"ok": False, "error": "invalid_json"})
            return

        if parsed.path == "/v1/documents":
            try:
                result = insert_document(payload)
            except ValueError as exc:
                self._json(400, {"ok": False, "error": str(exc)})
                return
            self._json(200, result)
            return

        if parsed.path == "/v1/search":
            rows = search_documents(
                payload.get("q", ""),
                limit=payload.get("limit", DEFAULT_LIMIT),
                agent=payload.get("agent", ""),
                task=payload.get("task", ""),
            )
            self._json(200, {"ok": True, "items": rows})
            return

        self._json(404, {"ok": False, "error": "not_found"})

    def log_message(self, format, *args):
        return

    def _set_common_headers(self, content_type):
        self.send_header("Content-Type", content_type)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")

    def _text(self, status, text):
        payload = text.encode("utf-8")
        self.send_response(status)
        self._set_common_headers("text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _json(self, status, obj):
        payload = json.dumps(obj, ensure_ascii=True).encode("utf-8")
        self.send_response(status)
        self._set_common_headers("application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _html(self, status, doc):
        payload = doc.encode("utf-8")
        self.send_response(status)
        self._set_common_headers("text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def main():
    wait_for_db()
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    server.serve_forever()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
