# Primary ARM Host

## Recommendation

Yes, the primary ARM host should remain the frontdoor and lightweight worker plane.

Treat it as the control point for:

- Slack-facing interaction
- frontdoor routing and user updates
- lightweight code-capable research tasks
- browser/proxy containers
- durable memory service

## Suggested Role Split

- primary ARM host
  Frontdoor sandbox, lightweight worker sandbox, browser/proxy containers, memory service
- local model-serving API / cloud inference
  Inference
- secondary x86 worker host
  Build-heavy verification, native toolchains, and disposable validation targets

## Boundary Rules

- keep Slack tokens only on the frontdoor side
- keep raw provider keys out of OpenClaw config when a host-side proxy is used
- keep the ARM worker lighter than the x86 worker
- do not use the ARM host as the heavy build or disposable VM plane when x86 is available
- keep host Docker off Slack-facing sandboxes

## Practical Uses

- frontdoor roles such as `communicator`, `general_assistant`, `vuln_researcher`, and `orchestrator`
- lightweight source inspection or coordination work
- memory-service hosting
- browser automation through the separate browser container
- provider proxy hosting when native provider auth is not selected

## What Belongs Here

- message intake and delivery
- session routing
- short-lived research coordination
- durable note storage
- small or low-risk worker tasks that do not need `x86_64`

## What Does Not Belong Here

- large native builds
- heavy fuzzing
- debugger-heavy validation
- disposable VM validation
- heavyweight long-running verification that is better isolated on x86

## Deployment Pattern

The clean pattern is:

1. keep `nemobot` on the primary ARM host
2. keep `nemoworker` on the same ARM host for lightweight code-capable tasks
3. use the x86 worker only when the task needs more architecture fit, CPU, RAM, or disposable validation targets
4. keep the ARM host focused on coordination, delivery, and lightweight analysis

## Why This Layout Works

- the frontdoor stays close to Slack and the helper services it depends on
- the lightweight worker remains available even when the x86 host is offline
- heavy validation can still be isolated away from the chat-facing trust boundary
- the split is simple: `arm` for frontdoor/lightweight work, `x86` for heavy analysis and validation
