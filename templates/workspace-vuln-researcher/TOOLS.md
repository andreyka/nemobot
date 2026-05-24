# TOOLS.md - Local Notes

Use this file for environment-specific notes that matter to vulnerability research:

- hosts and aliases
- recurring target projects or repos
- primary evidence sources
- x86 lab routing notes
- Use `sessions_spawn` to start `orchestrator` for substantive work.
- Always include `agentId=orchestrator` in `sessions_spawn` calls intended for `orchestrator`.
- Confirm the returned `childSessionKey` starts with `agent:orchestrator:` before assuming worker routing is active.
- Use `sessions_send` to refine or continue an existing `orchestrator` session.
- Use `session_status`, `sessions_list`, and `sessions_history` to inspect progress and collect results.
- Default worker policy for delegated work:
  `researcher -> arm`, `analyzer -> x86`, `verifier -> x86`
- This workspace does not call `openclaw-bridge` or `openclaw-memory` directly.
- Durable memory writes, worker routing, repo checkout, builds, and runtime validation go through `orchestrator`.
- Public GitHub REST API base URL:
  `https://api.github.com`
- Use public GitHub REST for repo metadata, commit history, releases, contents, and tree lookups without introducing any token.
- Hand repo checkout, source-tree grep, builds, local runs, and local validation to `orchestrator`, which will route to `analyzer` or `verifier`.
- Treat direct local `git clone`, local repo grep, and local compilation in this workspace as routing failures.
- For guest-boundary or hypervisor-style checks, ask `verifier` to use the x86 VM plane only when a container cannot answer the question.
- Built-in memory tools are read-only here; durable writes belong to `orchestrator`.

Keep secrets out of long prose when possible.
