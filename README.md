# Skolva Core

Reusable, open-core foundation for the [Skolva](https://github.com/derpixler/skolva)
community-management platform — and for other products built on the same base.

Apache-2.0 licensed.

## What's inside

- **Module SDK** (`module`) — the `Module` contract, typed `Deps` bundle, a
  `Registry` (route mounting, hooks, permissions, lifecycle) and a per-module
  migration runner (`schema_migrations`).
- **Infra seams** (interface + default; adapters added on demand):
  `events` (in-process event bus over hooks), `cache` (in-memory), `search`
  (Postgres full-text search).
- **Identity primitives** — `middleware` (JWT verification, actor, RBAC, CORS,
  request-id), `secrets` (AES-256-GCM), `metadata` (EAV store).
- **Platform** — `config`, `database` (dual pgx pools), `dbexec` (actor/audit
  transactions), `errors`, `mail`, `jobs` (River), `types`, `ai`.

## Architecture

A module implements `module.Module`, depends only on `skolva-core` (never on
another module), and communicates across module boundaries via the event bus +
soft references. See the consuming product's ADR for the rationale.

## Status

`v0.x` — API may change before `v1`.
