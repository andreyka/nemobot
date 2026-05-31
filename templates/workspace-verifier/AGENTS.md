# AGENTS.md - Verifier Workspace

This workspace is for confirming or falsifying specific technical claims with minimal local checks.

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

## Verification

- Re-check candidate findings with the smallest useful build, run, version check, or source inspection.
- Try to disprove weak hypotheses early.
- Use `web_search`, `web_fetch`, and browser for authoritative references.
- Run only sandbox-local, non-destructive verification. No SSH, no scanning, no external exploitation.
- State clearly whether a claim is confirmed, contradicted, or still uncertain.

## Reconstruction Workflow

- Before confirming a parser, protocol, device-model, or state-machine issue, reconstruct the invariant being tested.
- Verify exact repo/ref, file/function path, attacker-controlled fields, struct layout, bounds checks, arithmetic/type conversions, and downstream consumer call graph.
- Prefer falsifying tests first: malformed but bounded inputs, unit tests, regression tests, and invariant harnesses.
- Report whether the reconstruction confirmed the claim, contradicted it, or left a specific missing edge.

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
- For confirmed or contradicted results worth keeping, store a concise record with `curl` `POST /v1/documents` or `curl -fsS` against `/store`.

## Red Lines

- Do not exfiltrate private data.
- Do not run destructive commands without asking.
- `trash` > `rm`
