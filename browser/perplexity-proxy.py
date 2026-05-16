#!/usr/bin/env python3
import http.server
import json
import os
import socketserver
import urllib.error
import urllib.request


UPSTREAM_URL = "https://api.perplexity.ai/chat/completions"
TIMEOUT = 180


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _auth_header(self) -> str:
        api_key = os.environ.get("PERPLEXITY_API_KEY", "").strip()
        if not api_key:
            raise RuntimeError("PERPLEXITY_API_KEY is not configured")
        return f"Bearer {api_key}"

    def do_GET(self):
        if self.path in ("/healthz", "/health"):
            body = b'{"ok":true}\n'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path in ("/models", "/v1/models"):
            body = json.dumps(
                {
                    "object": "list",
                    "data": [
                        {
                            "id": "sonar-pro",
                            "object": "model",
                            "owned_by": "perplexity",
                        }
                    ],
                }
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self.send_error(404)

    def do_POST(self):
        if self.path not in ("/chat/completions", "/v1/chat/completions"):
            self.send_error(404)
            return

        content_length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(content_length)
        try:
            req = urllib.request.Request(
                UPSTREAM_URL,
                data=body,
                method="POST",
                headers={
                    "Authorization": self._auth_header(),
                    "Content-Type": "application/json",
                },
            )
            with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                response_body = resp.read()
                status = resp.status
                content_type = resp.headers.get("Content-Type", "application/json")
        except urllib.error.HTTPError as exc:
            response_body = exc.read()
            status = exc.code
            content_type = exc.headers.get("Content-Type", "application/json")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(response_body)))
        self.end_headers()
        self.wfile.write(response_body)


class ReusableTCPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True


if __name__ == "__main__":
    with ReusableTCPServer(("0.0.0.0", 9003), Handler) as httpd:
        httpd.serve_forever()
