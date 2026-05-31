# TOOLS.md - Local Notes

Use this file for environment-specific notes that matter to research work:

- hosts and aliases
- target repos or mirrors
- browser targets
- build or exploit caveats
- Preferred helper:
  `openclaw-bridge --agent researcher|analyzer|verifier --session <short-key> --query '<delegated prompt>'`
- Preferred long-job flow:
  `openclaw-bridge submit --agent analyzer|verifier --session <short-key> --query '<delegated prompt>'`
- Poll or wait:
  `openclaw-bridge status --job <target:id>`
  `openclaw-bridge wait --job <target:id> --timeout <seconds>`
- Default target selection:
  `researcher -> arm`, `analyzer -> x86`, `verifier -> x86`
- Explicit override when needed:
  `openclaw-bridge --target arm|x86 --agent <agent> --session <short-key> --query '<delegated prompt>'`
- Use `openclaw-bridge` for worker routing because `web_fetch` blocks the private-cluster-only bridge hostnames.
- Do not use raw `curl` against worker bridge service names from this workspace; it will miss the exec allowlist.
- This workspace is runtime-restricted to `openclaw-bridge` and `openclaw-memory` for `exec`.
- Memory service base URL:
  `http://host.openshell.internal:9004`
- Search:
  `openclaw-memory search --query '<terms>' --task '<optional-task>'`
- Store note:
  `openclaw-memory store-note --agent orchestrator --task '<task>' --title '<title>' --summary '<summary>' --body-file <path>`
- Store file:
  `openclaw-memory store-file --agent orchestrator --task '<task>' --path <path> --title '<title>'`
- Durable success means `openclaw-memory` returned `ok: true` and a numeric `id`.

Keep secrets out of long prose when possible.
