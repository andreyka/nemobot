#!/usr/bin/env python3
import argparse
import html.parser
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request


TARGETS = {
    "arm": "http://openclaw-worker-bridge.openshell.svc.cluster.local:8080",
    "pi": "http://openclaw-worker-bridge.openshell.svc.cluster.local:8080",
    "x86": "http://openclaw-x86-worker-bridge.openshell.svc.cluster.local:8080",
}
AGENTS = {"researcher", "analyzer", "verifier"}
SESSION_RE = re.compile(r"[^a-zA-Z0-9._:-]+")


class _HTMLToText(html.parser.HTMLParser):
    BLOCK_TAGS = {
        "body",
        "br",
        "div",
        "h1",
        "h2",
        "h3",
        "h4",
        "h5",
        "h6",
        "li",
        "p",
        "pre",
        "section",
        "tr",
        "ul",
    }

    def __init__(self):
        super().__init__()
        self.parts = []
        self._skip_depth = 0

    def handle_starttag(self, tag, attrs):
        if tag in {"script", "style"}:
            self._skip_depth += 1
            return
        if self._skip_depth:
            return
        if tag in self.BLOCK_TAGS:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in {"script", "style"} and self._skip_depth:
            self._skip_depth -= 1
            return
        if self._skip_depth:
            return
        if tag in self.BLOCK_TAGS:
            self.parts.append("\n")

    def handle_data(self, data):
        if self._skip_depth:
            return
        self.parts.append(data)

    def text(self):
        joined = "".join(self.parts)
        lines = [line.rstrip() for line in joined.splitlines()]
        compact = "\n".join(line for line in lines if line.strip())
        return compact.strip()


def add_run_like_args(parser):
    parser.add_argument(
        "--agent",
        required=True,
        choices=sorted(AGENTS),
        help="Worker agent to invoke.",
    )
    parser.add_argument(
        "--target",
        choices=("auto", "arm", "pi", "x86"),
        default="auto",
        help="Bridge target. Defaults to arm for researcher and x86 for analyzer/verifier. `pi` remains accepted as a legacy alias.",
    )
    parser.add_argument(
        "--session",
        required=True,
        help="Short stable session key for the delegated run.",
    )
    parser.add_argument(
        "--query",
        help="Delegated prompt text.",
    )
    parser.add_argument(
        "--query-file",
        help="Read delegated prompt text from a file.",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=1800,
        help="Worker timeout or wait timeout in seconds.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print raw JSON instead of a human-readable summary.",
    )
    parser.add_argument(
        "--raw",
        action="store_true",
        help="For sync runs, print raw bridge HTML/text instead of stripping HTML.",
    )


def add_job_args(parser, *, wait=False):
    parser.add_argument(
        "--job",
        help="Job reference in the form <target>:<id>.",
    )
    parser.add_argument(
        "--target",
        choices=("arm", "pi", "x86"),
        help="Bridge target when --job is not used.",
    )
    parser.add_argument(
        "--id",
        help="Bridge job id when --job is not used.",
    )
    if wait:
        parser.add_argument(
            "--timeout",
            type=int,
            default=1800,
            help="How long to wait for job completion before returning.",
        )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print raw JSON instead of a human-readable summary.",
    )


def parse_args():
    argv = sys.argv[1:]
    commands = {"run", "submit", "status", "wait"}
    if not argv or argv[0] not in commands:
        argv = ["run", *argv]

    parser = argparse.ArgumentParser(
        description="Call the private OpenClaw worker bridges with safe defaults."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    run_parser = subparsers.add_parser("run", help="Run a synchronous worker request.")
    add_run_like_args(run_parser)

    submit_parser = subparsers.add_parser("submit", help="Submit an asynchronous worker request.")
    add_run_like_args(submit_parser)

    status_parser = subparsers.add_parser("status", help="Inspect an asynchronous worker request.")
    add_job_args(status_parser)

    wait_parser = subparsers.add_parser("wait", help="Wait for an asynchronous worker request.")
    add_job_args(wait_parser, wait=True)

    return parser.parse_args(argv)


def sanitize_session(session):
    sanitized = SESSION_RE.sub("-", session).strip("-")
    if not sanitized:
        raise SystemExit("session must contain at least one safe character")
    return sanitized[:160]


def read_query(args):
    if getattr(args, "query", None) and getattr(args, "query_file", None):
        raise SystemExit("use either --query or --query-file, not both")
    if getattr(args, "query_file", None):
        with open(args.query_file, "r", encoding="utf-8") as fh:
            query = fh.read()
    else:
        query = getattr(args, "query", None) or ""
    query = query.strip()
    if not query:
        raise SystemExit("query must not be empty")
    return query


def pick_target(agent, requested_target):
    if requested_target != "auto":
        return requested_target
    if agent == "researcher":
        return "arm"
    return "x86"


def parse_job_ref(job_ref, target, job_id):
    if job_ref:
        if ":" not in job_ref:
            raise SystemExit("job must be in the form <target>:<id>")
        target, job_id = job_ref.split(":", 1)
        if target not in TARGETS:
            raise SystemExit(f"unknown target in job ref: {target}")
        if not job_id:
            raise SystemExit("job id must not be empty")
        return target, job_id
    if not target or not job_id:
        raise SystemExit("use --job or provide both --target and --id")
    return target, job_id


def strip_html(body):
    parser = _HTMLToText()
    parser.feed(body)
    parser.close()
    return parser.text() or body


def fetch_text(url, timeout):
    req = urllib.request.Request(url, headers={"Accept": "text/html, text/plain"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        print(
            f"openclaw-bridge http error status={exc.code}",
            file=sys.stderr,
        )
        if detail:
            print(strip_html(detail), file=sys.stderr)
        raise SystemExit(1)
    except urllib.error.URLError as exc:
        print(f"openclaw-bridge network error: {exc}", file=sys.stderr)
        raise SystemExit(1)


def fetch_json(url, timeout):
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.getcode(), json.loads(resp.read().decode("utf-8", errors="replace"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        print(
            f"openclaw-bridge http error status={exc.code}",
            file=sys.stderr,
        )
        if detail:
            print(detail, file=sys.stderr)
        raise SystemExit(1)
    except urllib.error.URLError as exc:
        print(f"openclaw-bridge network error: {exc}", file=sys.stderr)
        raise SystemExit(1)


def render_submit(result, target):
    job = result["job"]
    job_ref = f"{target}:{job['id']}"
    return "\n".join(
        [
            "ok: true",
            f"target: {target}",
            f"id: {job['id']}",
            f"job: {job_ref}",
            f"status: {job['status']}",
            f"wait: openclaw-bridge wait --job {job_ref} --timeout {job['timeoutSeconds']}",
        ]
    )


def render_status(result, target):
    job = result["job"]
    lines = [
        f"job: {target}:{job['id']}",
        f"agent: {job['agent']}",
        f"session: {job['session']}",
        f"status: {job['status']}",
        f"detail: {job['detail']}",
    ]
    if job.get("finishedAt"):
        lines.append(f"finishedAt: {job['finishedAt']}")
    return "\n".join(lines)


def render_wait(result, target):
    job = result["job"]
    if job["status"] == "succeeded":
        return job.get("result", "").strip()
    if job["status"] in {"queued", "running"}:
        return (
            f"job: {target}:{job['id']}\n"
            f"status: {job['status']}\n"
            f"detail: {job['detail']}"
        )
    raise SystemExit(
        f"openclaw-bridge job failed job={target}:{job['id']} detail={job['detail']}\n{job.get('result', '').strip()}"
    )


def main():
    args = parse_args()

    if args.command == "run":
        session = sanitize_session(args.session)
        query = read_query(args)
        target = pick_target(args.agent, args.target)
        params = urllib.parse.urlencode(
            {
                "agent": args.agent,
                "session": session,
                "timeout": str(args.timeout),
                "q": query,
            }
        )
        body = fetch_text(f"{TARGETS[target]}/run?{params}", args.timeout)
        if args.raw:
            print(body)
            return
        print(strip_html(body))
        return

    if args.command == "submit":
        session = sanitize_session(args.session)
        query = read_query(args)
        target = pick_target(args.agent, args.target)
        params = urllib.parse.urlencode(
            {
                "agent": args.agent,
                "session": session,
                "timeout": str(args.timeout),
                "q": query,
            }
        )
        _, result = fetch_json(f"{TARGETS[target]}/submit?{params}", max(args.timeout, 60))
        if args.json:
            print(json.dumps(result, indent=2))
            return
        print(render_submit(result, target))
        return

    target, job_id = parse_job_ref(args.job, args.target, args.id)
    params = {"id": job_id}
    if args.command == "wait":
        params["timeout"] = str(args.timeout)
        code, result = fetch_json(
            f"{TARGETS[target]}/wait?{urllib.parse.urlencode(params)}",
            max(args.timeout, 60),
        )
        if args.json:
            print(json.dumps(result, indent=2))
            if code not in {200, 202}:
                raise SystemExit(1)
            return
        if code == 202:
            print(render_wait(result, target))
            raise SystemExit(2)
        print(render_wait(result, target))
        return

    _, result = fetch_json(f"{TARGETS[target]}/status?{urllib.parse.urlencode(params)}", 60)
    if args.json:
        print(json.dumps(result, indent=2))
        return
    print(render_status(result, target))


if __name__ == "__main__":
    main()
