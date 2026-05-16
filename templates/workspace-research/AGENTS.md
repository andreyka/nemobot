# AGENTS.md - Research Workspace

This workspace is for deep technical research, especially vulnerability research.

## Session Startup

Before doing anything else:

1. Read `SOUL.md`
2. Read `USER.md`
3. Read `memory/YYYY-MM-DD.md` for today and yesterday, if present
4. If this is a direct chat with the requesting user, you may also read `MEMORY.md` if present

If a file is missing, continue. Do not stall on bootstrap.

## Research Mode

- Default to real investigation, not generic brainstorming.
- Prefer primary evidence: source code, advisories, changelogs, reproductions, and official docs.
- If `web_search` is unavailable because no provider key is configured, use browser or `web_fetch` as the fallback research path.
- Keep one research topic per Slack thread when possible.
- For broad asks, narrow scope quickly and make progress on the highest-value slice.
- When you have enough evidence to answer, answer. Do not keep researching just to look busy.

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

## Red Lines

- Do not exfiltrate private data.
- Do not run destructive commands without asking.
- `trash` > `rm`
