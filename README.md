# Nemobot

Nemobot packages a split OpenClaw stack for security research, discovery, verification, and reporting. The recommended deployment shape uses a primary ARM host plus a secondary x86 worker host:

- frontdoor sandbox `nemobot` for Slack-facing interaction with `communicator -> general_assistant|vuln_researcher`
- ARM worker sandbox `nemoworker` for lightweight code-capable research work
- optional x86 worker sandbox `nemox86worker` for build-heavy verification and disposable validation targets
- public GitHub repo access over HTTPS and GitHub REST without any repo token
- host-side Docker containers for browser, provider proxies, and the memory service
- in-cluster worker bridge so the frontdoor can delegate without holding worker credentials
- persistent OpenClaw config and prompt files outside the pod-local filesystem

Official external OpenClaw plugins and the stable OpenShell images used by the
stack are pinned in [release.env](release.env). Build scripts, local cluster
resets, and remote lab deploys consume those pins, and sandbox startup
re-syncs the Slack plugin to the same OpenClaw release if the managed npm root
has drifted.

In the current design, `vuln_researcher` is a lightweight security frontdoor. It does lead generation itself with `web_search` and `web_fetch`, then spawns `orchestrator` for any code checkout, build, bridge, VM, or durable-memory work. `orchestrator` owns `exec` and routes concrete jobs to `researcher`, `analyzer`, and `verifier`.

## Quick Start

Use the guided bootstrap if you want the installer to prompt for hosts, tokens, and optional x86 lab details:

```bash
./bootstrap.sh
```

For a rebuild/update of an existing deployment, use:

```bash
./reinstall.sh
```

Or initialize local state first:

```bash
./stack-install.sh --init-state
```

Then provide the expected environment and deploy the whole stack:

```bash
export MODEL_API_BASE_URL=http://model-api.example.internal:8001/v1
export MODEL_API_MODEL_ID=provider/model-name
export WORKER_CODE_MODEL_ID=nvidia/nemotron-3-super-120b-a12b
export MODEL_CONTEXT_WINDOW=131072
export SLACK_BOT_TOKEN='<set-in-local-state>'
export SLACK_APP_TOKEN='<set-in-local-state>'
export NVIDIA_API_KEY='<set-in-local-state>'
export PERPLEXITY_API_KEY='<set-in-local-state>'
export PERPLEXITY_MODEL=sonar-pro
export TIMEOUT_SECONDS=2400
./stack-install.sh
```

To use Anthropic Claude natively through OpenClaw, prefer a Claude subscription setup-token. Generate it with `claude setup-token` on any machine, then export it here instead of `MODEL_API_BASE_URL` and `MODEL_API_MODEL_ID`. Nemobot will keep the token in ignored local state and import it into OpenClaw inside each sandbox at startup.

```bash
export ANTHROPIC_AUTH_MODE=setup-token
export ANTHROPIC_SETUP_TOKEN='<set-in-local-state>'
export ANTHROPIC_MODEL=claude-opus-4-7
export WORKER_CODE_MODEL_ID=claude-opus-4-7
export SLACK_BOT_TOKEN='<set-in-local-state>'
export SLACK_APP_TOKEN='<set-in-local-state>'
./stack-install.sh
```

Anthropic API keys still work as a fallback, but they now use the same native OpenClaw provider path instead of the legacy host-side Anthropic proxy:

```bash
export ANTHROPIC_AUTH_MODE=api-key
export ANTHROPIC_API_KEY='<set-in-local-state>'
export ANTHROPIC_MODEL=claude-opus-4-7
export WORKER_CODE_MODEL_ID=claude-opus-4-7
./stack-install.sh
```

If you only want to deploy the frontdoor sandbox and host-side containers:

```bash
./install.sh
```

## Bundle Layout

- `stack-install.sh`
  End-to-end installer for frontdoor, worker, and bridge
- `bootstrap.sh`
  Interactive bootstrap wrapper that prompts for deployment-specific hosts, tokens, and optional x86 lab settings
- `reinstall.sh`
  Safe rebuild/update wrapper that preserves durable memory by default and can also update the x86 worker host
- `install.sh`
  Frontdoor installer for `nemobot` plus host-side Docker containers
- `worker/install.sh`
  Worker installer for `nemoworker`
- `x86-lab/install-remote.sh`
  Deploys the x86 build/validation worker as a dedicated OpenShell cluster plus host-side helper containers on a separate host
- `x86-lab/install-bridge.sh`
  Deploys the frontdoor-host bridge that proxies requests to the x86 worker gateway
- `x86-lab/lab-control.py`
  Bounded x86 lab-control service for disposable cluster-local jobs
- `worker/prepare-state.sh`
  Builds worker-local state from the worker template plus shared frontdoor model/search settings
- `worker/render-worker-state.py`
  Renders `worker/state/openclaw.json` without inheriting frontdoor Slack/env secrets
- `bridge/install.sh`
  In-cluster bridge deployment
- `browser/`
  Hardened host-side Docker containers for browser, NVIDIA/Perplexity proxies, Postgres, and memory service
- `templates/`
  Frontdoor config and prompt templates
- `worker/templates/`
  Worker config and prompt templates
- `docs/ARCHITECTURE.md`
  Deployment shape, trust boundaries, and OpenShell primitives
- `docs/OPERATIONS.md`
  Install, update, and troubleshooting flow
- `docs/ARM_WORKER.md`
  Recommended shape for the primary ARM frontdoor and lightweight worker host
- `docs/MEMORY.md`
  Recommended memory-service design
- `docs/X86_WORKER.md`
  Recommended shape for a secondary x86 build and validation host
- `state/runtime.env`
  Frontdoor runtime secrets injected as env vars into `nemobot`
- `state/model-auth.env`
  Shared in-sandbox model auth for native OpenClaw providers such as Anthropic setup-token or Anthropic API key
- `state/nvidia-proxy.env`
  Host-only NVIDIA cloud credential for the local proxy container
- `state/perplexity-proxy.env`
  Host-only Perplexity credential for the local proxy container
- `state/memory-service.env`
  Host-only Postgres credentials and memory-service settings

## Notes

- `state/` and `backups/` are intentionally local and should not be committed
- `reinstall.sh` preserves the named Postgres volume for durable memory and writes a SQL backup when `openclaw-memory-db` is running
- this bundle assumes the base OpenShell cluster already exists on the primary ARM host
- OpenClaw runs inside OpenShell sandbox pods, not directly on the host
- browser isolation is a hardened container boundary, not a separate VM
- the worker config is rendered from its own template; it is not a copy of frontdoor runtime state
- the x86 worker host is a separate compose project and bridge target, not part of the frontdoor or the primary ARM host helper containers
- `communicator` is intentionally lightweight and should delegate real work rather than trying to research inline
- `vuln_researcher` does not have local shell access; it must hand substantive code and runtime work to `orchestrator`
- the primary inference backend only needs to expose a compatible model-serving API; it does not depend on a specific hardware vendor
- Anthropic Claude subscription auth is handled natively inside OpenClaw via setup-token; it does not require the host-side Anthropic proxy
- analyzer and verifier default to `WORKER_CODE_MODEL_ID` for code-heavy tasks; it must support OpenClaw tool use on your proxy path
- public GitHub repo access is intentionally tokenless; use HTTPS clone and `https://api.github.com` for public metadata
- disposable validation environments on x86 are bounded jobs behind lab-control, not broad Docker or VM access from the bot
- long worker runs should use the async bridge flow: `openclaw-bridge submit`, then `status` or `wait`
- the x86 lab now exposes a narrow VM plane through `lab-control /vm/run` for guest-boundary and runtime validation

## License

Nemobot is licensed under Apache License 2.0. See [LICENSE](LICENSE).

## Naming Migration

Fresh tracked defaults now use `nemobot` naming:

- cluster container: `openshell-cluster-nemobot`
- sandbox image tags: `openshell/sandbox-from:nemobot` and `openshell/sandbox-from:x86-nemobot`
- persisted mount root: `/opt/openclaw-nemobot`

Older deployments may still use `openshell-cluster-nemoclaw`, `openshell/sandbox-from:vulnlab`, or `/opt/openclaw-vulnlab`. The install and entrypoint scripts keep compatibility fallbacks for those older names so rebuilds and updates do not require a manual rename first.
