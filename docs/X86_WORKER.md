# Secondary x86 Worker Host

## Recommendation

Yes, a secondary `x86_64` host is a good next target for build-heavy verification work.

Do not treat it as another chat-facing bot. Treat it as a separate lab plane for:

- `x86_64` builds
- debuggers and fuzzers
- disposable validation targets
- reproduction environments that are awkward on the ARM host

## Suggested Role Split

- primary ARM host
  Frontdoor sandbox, orchestration, browser/proxy containers, memory service
- local model-serving API / NVIDIA cloud
  Inference
- x86 worker host
  Build-heavy worker tasks and optional disposable validation VMs or containers

## Boundary Rules

- no Slack tokens on the lab host
- no Slack tokens in the lab sandbox
- no raw NVIDIA or Perplexity keys in OpenClaw config
- no direct chat access to the lab host
- no host Docker socket mounted into any Slack-facing sandbox
- use it for isolated validation, not live target interaction

## Practical Uses

- build and run `x86_64` PoCs or test harnesses
- run `afl++`, sanitizers, debuggers, or heavier native toolchains
- host disposable VMs for validating hypotheses in a contained environment
- keep the ARM host focused on frontdoor and lightweight worker control

## Deployment Pattern

The clean pattern is:

1. keep `nemobot` on the primary ARM host
2. keep the main ARM worker split on that host unless or until it becomes too slow
3. add the `x86_64` host as a second-tier worker or validation host, not as a replacement frontdoor
4. run a dedicated OpenShell cluster container on the x86 host, plus separate browser/proxy helper containers on that same host
5. run the x86 worker as an OpenShell `Sandbox`, not as a standalone OpenClaw container
6. let frontdoor-side orchestration delegate build-heavy or validation-heavy steps there through a narrow bridge
7. expose disposable local validation through a bounded cluster-local lab-control service, not raw Docker access

## Why This Is Better Than Scaling the ARM Host

- same trust model, better target architecture fit
- better native support for common research tooling
- better fit for disposable VMs
- much higher ROI than scaling the chat/control plane

## What This Is Not

This is not intended to be a live attack platform.

Use it for controlled validation environments, reproducible builds, and disposable local targets only.

## Current Bundle Shape

The x86 bundle now follows the same trust model as the primary ARM host:

- a dedicated OpenShell cluster container runs on the x86 host, pinned through `release.env`
- the worker itself runs inside an OpenShell `Sandbox`
- browser, NVIDIA proxy, and Perplexity proxy run as separate host-side containers
- the worker gateway is exposed through a dedicated `NodePort` mapping, not by running OpenClaw directly on the host
- the frontdoor host talks to the x86 worker only through a token-protected bridge
- disposable validation jobs run through `lab-control` in namespace `openshell-lab` with fixed images and resource quotas

## Public GitHub Access

Public GitHub access on the worker side should stay tokenless unless you later need higher API limits.

Recommended paths:

- clone over HTTPS: `https://github.com/<owner>/<repo>.git`
- raw files: `https://raw.githubusercontent.com/...`
- REST metadata: `https://api.github.com/repos/<owner>/<repo>`

This keeps public repo access available without adding a new secret surface.
