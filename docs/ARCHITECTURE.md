# Architecture

Nemobot layers a split OpenClaw deployment on top of an existing OpenShell cluster on a primary ARM host, with an optional secondary x86 worker host for heavier validation work.

## Diagram

```text
requested user
    |
    v
Slack workspace
    |
    v
nemobot sandbox (OpenShell Sandbox CR + pod)
    |
    |  main / communicator / general_assistant / vuln_researcher / orchestrator
    |  - Slack-facing
    |  - no raw vendor keys in config
    |  - communicator routes into specialist frontdoor roles
    |  - main / communicator / general_assistant stay non-shell
    |  - vuln_researcher stays non-shell and can only use web/session/memory-read tools
    |  - orchestrator owns private bridge and durable-memory exec
    |  - web_search + web_fetch + sessions
    |
    +------------------------------+
    |                              |
    | browser tool                 | host.openshell.internal
    v                              v
openclaw-worker-bridge        host-side Docker containers
(k8s Deployment + Service)    - openclaw-cdp-browser
    |                          - openclaw-nvidia-proxy
    | bearer auth              - openclaw-perplexity-proxy
    |                          - openclaw-memory-db
    |                          - openclaw-memory-service
    v
nemoworker sandbox (OpenShell Sandbox CR + pod)
    |
    |  researcher / analyzer / verifier
    |  - no Slack tokens
    |  - no NVIDIA or Perplexity keys
    |  - may hold Anthropic native auth when configured
    |  - code/build/browser/web tools
    |  - local workspace and notes
    |
    +------------------------------+
    |                              |
    | optional delegated build /   v
    | validation work       local model-serving API / NVIDIA cloud / Perplexity
    v
secondary x86 worker host
    |
    |  separate OpenShell cluster container
    |  separate browser / proxy containers
    |  no Slack tokens in the worker sandbox
    |  no raw vendor keys in worker config
    v
nemox86worker sandbox
    - build-heavy analysis / verification
    - disposable validation targets only
    - not directly reachable from Slack
    - can use a bounded cluster-local lab-control service for ephemeral jobs
```

## Component Roles

### Frontdoor sandbox: `nemobot`

- Owns Slack connectivity.
- Hosts `main`, `communicator`, `general_assistant`, `vuln_researcher`, and `orchestrator`.
- Keeps `main`, `communicator`, and `general_assistant` off shell/code tools.
- `communicator` is the Slack-facing classifier and reporter.
- `general_assistant` handles non-security and ordinary technical requests.
- `vuln_researcher` is the vulnerability-research frontdoor and triage role.
- `vuln_researcher` is intentionally non-shell. It can do `web_search`, `web_fetch`, session management, and memory reads, but it cannot execute local commands.
- `orchestrator` owns the substantive vulnerability-research loop after triage. It performs bridge calls, durable-memory writes, and dispatch to code-capable worker agents.
- Holds Slack bot/app tokens only via an env secret, not literal config values.

### Worker sandbox: `nemoworker`

- Hosts `researcher`, `analyzer`, and `verifier`.
- Owns the code-capable tool surface: local file work, builds, non-destructive execution, browser, `web_search`, and `web_fetch`.
- Does not hold Slack credentials.
- Does not hold raw NVIDIA or Perplexity API keys.
- Renders its own `openclaw.json` from [arm-worker/templates/openclaw.template.json](../arm-worker/templates/openclaw.template.json) plus shared model/search settings from the frontdoor state, rather than inheriting the frontdoor runtime config.

### Worker bridge

- Runs as its own container in the cluster.
- Accepts a narrow HTTP request and forwards it to the worker gateway with the worker gateway token.
- Lets the frontdoor delegate work without learning the worker token.
- Because the bridge hostname is private-cluster-only, it is reached through `orchestrator` via `exec` + `curl`, not `web_fetch`.

### Host-side Docker containers

- `openclaw-cdp-browser`
  Separate hardened Chromium/CDP container used by both sandboxes.
- `openclaw-nvidia-proxy`
  Holds the NVIDIA cloud key and exposes an OpenAI-compatible endpoint to OpenClaw.
- `openclaw-perplexity-proxy`
  Holds the Perplexity key and exposes the search endpoint to OpenClaw.
- `openclaw-memory-db`
  PostgreSQL backing store for durable research memory.
- `openclaw-memory-service`
  Narrow HTTP API for storing and retrieving durable research notes without exposing DB credentials to the sandboxes.

These helpers are containers on the primary ARM host. OpenClaw talks to them through `host.openshell.internal`.

### Secondary x86 worker host

- Use this when the ARM worker is enough for orchestration but not ideal for `x86_64` builds, emulation, or disposable validation environments.
- Keep it off the Slack trust boundary.
- Run a dedicated OpenShell cluster container there, plus separate browser and proxy containers on that host.
- Run the worker itself as an OpenShell sandbox, not as a standalone OpenClaw container.
- Keep Slack tokens off the host entirely. NVIDIA and Perplexity keys should stay in host-side proxy containers; Anthropic setup-token or Anthropic API key may be mounted into the worker when native Anthropic auth is selected.
- Use it for local builds, fuzzing, debuggers, and throwaway validation VMs or containers.
- Do not expose it directly to chat users.
- In this bundle, it is represented as a second OpenShell deployment plus a dedicated frontdoor-host bridge target.

## OpenShell Primitives In Use

Yes. This setup is using the platform primitives instead of bypassing them.

- `Sandbox` custom resources
  `nemobot` and `nemoworker` are OpenShell sandbox objects, not ad hoc host processes.
- sandbox pod template patching
  [apply.sh](../apply.sh) rewrites the sandbox pod spec to mount persisted config and workspace content.
- Kubernetes `Secret`
  used for `openclaw.json` and frontdoor runtime env injection.
- Kubernetes `ConfigMap`
  used for the prompt/workspace files.
- custom sandbox image
  [Dockerfile.sandbox](../Dockerfile.sandbox) adds the persistent OpenClaw entrypoint and toolchain.
- OpenShell sandbox identity env vars
  `OPENSHELL_SANDBOX`, `OPENSHELL_SANDBOX_ID`, and `OPENSHELL_SSH_HANDSHAKE_SECRET` are preserved/set during deploy.
- in-cluster deployment/service
  the worker bridge is deployed as a Kubernetes `Deployment` and `Service`.

The important boundary is: OpenClaw still runs inside OpenShell sandboxes. We are not mounting host Docker into the agent pod, and we are not running OpenClaw directly on the host.

## Secret Boundary

The current design intentionally keeps secrets out of the code-capable worker trust domain.

### Frontdoor secrets

- Slack bot token and app token live in `state/runtime.env` on the primary ARM host and are injected into `nemobot` as env vars.
- The frontdoor `openclaw.json` stores `${SLACK_BOT_TOKEN}` and `${SLACK_APP_TOKEN}`, not literal tokens.

### Provider secrets

- NVIDIA key lives in `state/nvidia-proxy.env`.
- Perplexity key lives in `state/perplexity-proxy.env`.
- Anthropic setup-token or Anthropic API key lives in `state/model-auth.env` when native Anthropic auth is enabled.
- OpenClaw sees API-compatible model routes, the native `openai-codex` OAuth route, and local proxy URLs for NVIDIA and Perplexity. The preferred public backends are OpenAI/Codex API or OpenClaw `openai-codex` OAuth with credentials injected from ignored local state; Anthropic remains a native fallback path.

### Memory-service secrets

- Postgres credentials live in `state/memory-service.env`.
- Sandboxes do not receive the Postgres password directly.
- Sandboxes only see the memory-service HTTP endpoint on `host.openshell.internal:9004`.
- That endpoint is private/internal, so durable memory writes go through `orchestrator`, which uses `exec` + `curl`. Frontdoor roles use memory reads only unless they explicitly delegate.

### Worker secrets

- `nemoworker` does not receive Slack tokens.
- `nemoworker` does not receive NVIDIA or Perplexity keys.
- `nemoworker` may receive Anthropic setup-token or Anthropic API key via `state/model-auth.env` when native Anthropic auth is selected.
- `nemoworker` only receives its own gateway auth token.
- the secondary x86 worker host should follow the same rule
- public GitHub access is tokenless by default and uses HTTPS plus `https://api.github.com`

## Routing Model

The intended live flow is:

1. Slack reaches `communicator`.
2. `communicator` answers ordinary requests itself or spawns `vuln_researcher` for vulnerability-oriented work.
3. `vuln_researcher` does quick discovery and narrows the problem with `web_search` and `web_fetch`.
4. `vuln_researcher` spawns `orchestrator` for any code checkout, bridge call, build, VM, or durable-memory action.
5. `orchestrator` routes bounded work to `researcher`, `analyzer`, or `verifier`.
6. `communicator` reports the result back to Slack.

Environment-backed validation is a dedicated worker workflow:

1. `vuln_researcher` identifies the exact target version, config, and trust boundary.
2. `orchestrator` assigns environment preparation and bounded runtime work to workers.
3. `analyzer` owns target checkout, build, startup, and controlled reproducer setup.
4. `verifier` owns confirmation or falsification of the concrete claim.
5. The x86 VM plane is used when a container cannot model the boundary under test.

## Autonomous Research Workflow

Nemobot is designed to be steerable, not fully manual. For vulnerability research, the default behavior is:

1. infer safe defaults from the user request, usually latest public source unless a version or commit is named
2. search durable memory for prior work on the target or candidate
3. reconstruct the relevant parser, protocol, API, or state-machine invariant from primary evidence
4. delegate bounded source/build/runtime validation to workers
5. store useful milestones or artifacts in durable memory
6. synthesize a verdict, confidence level, impact limits, next step, and report-ready material

Nemobot should not ask the user to approve routine steps such as reading public source, cloning a public repo inside a worker, running non-destructive local tests, storing concise durable notes, or drafting a coordinated-disclosure report. It should ask for steering when the target is ambiguous, scope/legal boundaries are unclear, a step would be destructive or external, compute/spend would be substantial, or repeated bounded attempts hit the same blocker.

This keeps the user in control of target selection and risk boundaries while letting the system continue through evidence collection, validation, and reporting without requiring a new prompt for every step.

One known OpenClaw limitation remains: some spawned subagent runs can still inherit more of the parent workspace context than intended. The enforced tool boundary is still real, though: `vuln_researcher` does not have local `exec`, so shell-capable work must still pass through `orchestrator`.

This is better than the earlier single-sandbox design, but it is not an absolute non-leak proof system. Any secret mounted into a sandbox is still in that sandbox's trust domain. The current goal is narrower: keep Slack and vendor credentials out of the code-capable worker sandbox.

## Network and Tool Boundaries

- `nemobot` gateway binds to loopback only.
- `nemoworker` gateway binds to LAN inside the cluster because the bridge must reach it.
- the worker gateway is token-protected and should also use auth rate limiting.
- browser access goes to the separate CDP container, not a host desktop browser.
- the frontdoor browser allowlist includes only:
  - `host.openshell.internal`
  - `openclaw-worker-bridge`
  - `openclaw-worker-bridge.openshell.svc.cluster.local`

## Security Tradeoffs

Good:

- frontdoor and worker are separate sandboxes
- host-side helper services are separate containers
- NVIDIA and Perplexity keys are held by proxy containers, not by OpenClaw config
- the worker sandbox is isolated from Slack credentials
- a secondary x86 worker host can stay completely outside the Slack and vendor-key trust domains

Known tradeoffs:

- the browser boundary is still a container, not a VM
- remote CDP is plain HTTP on the internal bridge path
- the worker gateway must bind on cluster LAN for delegation
- the frontdoor still has Slack credentials because the Slack plugin requires them
- OpenAI/Codex API auth and Anthropic native auth place model credential material inside the OpenClaw sandbox trust domain when those backends are selected
- the x86 lab-control service can create only bounded disposable jobs, not arbitrary host workloads

## Memory Direction

The live stack now includes a dedicated memory-service container backed by PostgreSQL on the primary ARM host.

Current shape:

1. built-in OpenClaw memory still exists inside each sandbox for local scratch state
2. durable research memory lives behind `http://host.openshell.internal:9004`
3. the memory service, not OpenClaw, owns the Postgres credentials
4. storage is relational first; vector search can be added later if recall quality needs it

See [MEMORY.md](./MEMORY.md).
