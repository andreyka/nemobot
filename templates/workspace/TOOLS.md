# TOOLS.md - Local Notes

Use this file for environment-specific notes:

- SSH hosts and aliases
- Device names
- Preferred browser targets
- Deployment caveats
- Anything local that should not live in a shared skill
- Memory service base URL:
  `http://host.openshell.internal:9004`
- Frontdoor note:
  do not call the memory service directly with `web_fetch`; delegate durable memory actions to `orchestrator`

Keep secrets out of long prose when possible. Prefer references to where a secret is stored over pasting the secret itself.
