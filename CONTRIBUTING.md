# Contributing

## Ground Rules

- Keep tracked files free of secrets, tokens, private IPs, and machine-local paths.
- Do not commit anything under local state directories such as `state/`, `worker/state/`, `bridge/state/`, or `x86-lab/state/`.
- Keep frontdoor and worker trust boundaries intact. Do not move Slack or provider credentials into worker-facing config.

## Before Opening a Change

1. Describe the change and the trust boundary it affects.
2. Prefer generic defaults over operator-specific usernames, hostnames, and paths.
3. Update docs when changing install flows, image tags, mount roots, or helper services.

## Validation

Run the checks relevant to the files you changed.

Examples:

```bash
bash -n apply.sh
bash -n install.sh
bash -n worker/install.sh
bash -n x86-lab/install-remote.sh
```

If you change Python helper services or renderers, run a minimal import or syntax check as well.

## Security Hygiene

- Keep provider keys in env files or proxy containers, not in tracked config.
- Keep public GitHub access tokenless unless authenticated API access is actually required.
- Keep remote-install flows host-key-safe by default.
- Do not widen sandbox capabilities or helper-service exposure without documenting the tradeoff.

## Pull Requests

Include:

- what changed
- why it changed
- any trust-boundary or secret-handling impact
- how you validated it
