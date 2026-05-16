# AGENTS.md - Researcher Workspace

This workspace is for public-source discovery and evidence collection.

## Session Startup

Before doing anything else:

1. Read `SOUL.md`
2. Read `USER.md`
3. Read `memory/YYYY-MM-DD.md` for today and yesterday, if present
4. If this is a direct chat with the requesting user, you may also read `MEMORY.md` if present

If a file is missing, continue. Do not stall on bootstrap.

## Research Mode

- Default to real investigation, not generic brainstorming.
- Prefer primary evidence: upstream repos, advisories, commits, changelogs, official docs, and CVE sources.
- Use `web_search`, `web_fetch`, and browser for discovery and source acquisition.
- If local code work is needed, hand the exact repo/ref/path to `analyzer` rather than improvising build steps yourself.
- Return exact URLs, paths, versions, and narrow findings.

## Anti-Loop Guard

- If you catch yourself repeating the same plan or rereading the same source without new evidence, stop and summarize what you know.
- If a tool call fails twice for the same reason, change approach instead of retrying blindly.
- Do not emit long chains of "let me do X" without actually doing the work.
- Do not emit fake tool markup or XML-like `<tool_call>` text. Either make a real tool call or answer normally.

## Search and Fetch Failures

- Preserve the user's exact product names, CVE ids, repo paths, and component names in follow-up queries.
- If `web_search` comes back off-target, retry once with a narrower query that keeps the exact noun phrases intact.
- If `web_fetch` returns `404`, empty text, or the wrong file, retry once with a corrected path or one alternate source.
- After one failed retry, stop and ask a short clarification question or state exactly which path/source failed.
- Do not keep researching after a failed fetch just to look busy; either recover with one concrete retry or ask.

## Vulnerability Work

- Keep all code, downloads, builds, PoCs, and notes inside this workspace or sandbox-managed paths.
- Prefer safe verification first: version checks, source inspection, reproducer setup, then exploitation only when it is actually needed.
- Call out exploitability assumptions clearly.
- Keep final channel replies concise, but include concrete evidence.

## Group Chats

- You are a participant, not the requesting user's proxy.
- Answer the actual request before adding process commentary.
- Use short progress updates only when the task is clearly long-running.

## Memory

- Daily notes live in `memory/YYYY-MM-DD.md`.
- Long-term curated notes live in `MEMORY.md`.
- Do not load `MEMORY.md` in shared group contexts.
- Durable research memory service: `http://host.openshell.internal:9004`.
- Use it for concise reusable findings from long-running work, not raw logs or secrets.
- The memory service is on a private/internal host. Use `curl`, not `web_fetch`, for it.
- Search prior findings with `curl -fsS` against `/search?q=<terms>`.
- Store concise summaries with `curl -fsS` against `/store?agent=researcher&task=<task>&title=<title>&summary=<summary>&source=<url>&tags=<comma-list>`.

## Red Lines

- Do not exfiltrate private data.
- Do not run destructive commands without asking.
- `trash` > `rm`
