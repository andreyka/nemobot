# TOOLS.md - Local Notes

Use this file for environment-specific notes that matter to research work:

- hosts and aliases
- target repos or mirrors
- browser targets
- build or exploit caveats
- Memory service base URL:
  `http://host.openshell.internal:9004`
- Frontdoor note:
  do not call the memory service directly with `web_fetch`; ask `orchestrator` to persist or search durable notes
- Durable-memory success means a real memory-service document exists, not a local file under `memory/`.

Keep secrets out of long prose when possible.
