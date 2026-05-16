# Memory Service

## Recommendation

Use a regular database as the source of truth, with vector search as an optional secondary index.

Do not build this as a vector-only store.

For this setup, the recommended shape is:

1. a separate memory-service container
2. a relational database behind it
3. optional vector indexing for semantic retrieval
4. a narrow API that agents call instead of direct database access

## Why

Security research memory is not just embeddings. You need:

- durable notes
- source URLs and file paths
- extracted facts
- tags
- timestamps
- task/session linkage
- curated summaries
- explicit pinning and deletion

Those map naturally to a relational model. Vector search is useful, but it should help retrieval, not replace the data model.

## Current State

The live stack now has two memory layers:

- built-in OpenClaw memory inside each sandbox for local scratch state
- external memory service on `host.openshell.internal:9004` backed by PostgreSQL for durable research notes

That split is intentional. Built-in memory stays local to the sandbox. Durable research memory lives behind a narrow service boundary.

## Live Architecture

```text
frontdoor / worker agents
        |
        v
  memory-service container
        |
        +--> PostgreSQL
        |
        +--> optional embedding worker / vector index
```

The memory-service container, not OpenClaw, should own the database credentials.

## Suggested Data Model

Use these concepts:

- `documents`
  Canonical stored material: advisories, notes, code snippets, reports, copied source excerpts.
- `facts`
  Small normalized claims extracted from documents.
- `artifacts`
  Files, archives, logs, build outputs, or snapshots stored by path plus metadata.
- `tasks`
  Research runs or investigations.
- `links`
  Relations between tasks, documents, files, CVEs, repos, versions, and components.
- `embeddings`
  Optional table keyed to documents or chunks.

Each record should carry:

- source
- created time
- updated time
- created by agent
- task/session id
- sensitivity tag
- retention or pin state

## API Shape

Keep the API narrow and explicit.

Current endpoints:

- `GET /healthz`
  Liveness check.
- `GET /search?q=...`
  Browser-friendly search view.
- `GET /store?...`
  Browser-friendly write path for concise summaries.
- `POST /v1/documents`
  Rich JSON write path.
- `POST /v1/search`
  JSON search path.
- `GET /documents/:id`
  Read one item.
- `openclaw-memory`
  Sandbox-local helper CLI for agent-driven durable writes and lookups. Durable-memory confirmations should come from this helper's returned document id, not from a local `memory/` file path.

## Agent Workflow

The right workflow is explicit, not automatic by default.

- communicator
  asks the active specialist to store or search durable notes when explicitly asked
- vuln_researcher
  can query memory and store promoted notes through the private memory-service endpoint for security work
- orchestrator
  can query memory and store promoted notes for non-security coordination flows
- worker agents
  can propose memory candidates and attach evidence, and can write durable notes with `curl` when appropriate

Local `memory/*.md` files remain workspace scratch notes. They are not the external durable memory bank.

Avoid auto-saving every message or every fetched page. That creates noise and increases the chance of storing low-value or sensitive material accidentally.

## Storage Choice

Current fit:

- PostgreSQL as source of truth
- optional `pgvector` if you want semantic retrieval in the same system

That gives you:

- transactional updates
- strong filtering
- full-text search
- structured metadata
- optional vector search without introducing a separate database first

## Security Model

- do not give raw DB credentials to OpenClaw sandboxes
- keep DB credentials only in the memory-service container or its secret store
- expose only the memory API to the agents
- do not route private memory-service calls through `web_fetch`; use the narrow local command path for internal endpoints
- separate "search/get" from "write/promote" privileges if you want tighter control

## Suggested Next Step

The service is intentionally lexical plus metadata first.

The next improvement should be:

1. add update and delete endpoints
2. add optional auth if you want stronger separation between frontdoor and worker writes
3. add embeddings and `pgvector` only if search quality needs it
4. add promotion workflows from sandbox-local scratch memory into durable memory
