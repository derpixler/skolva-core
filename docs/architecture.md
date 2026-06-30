# Architecture

This document records the architectural decisions behind Skolva Core and the
module ecosystem it enables. It complements the [Module
Charter](module-charter.md), which covers the day-to-day rules for building and
extracting modules.

## Decision 1: Polyrepo

Core and each feature module are **autonomous Git repositories** with their
own SemVer (root tags `vX.Y.Z`), CI and issues:

- `derpixler/skolva-core` — infrastructure, module SDK, identity primitives
  (Apache-2.0).
- `derpixler/skolva-<name>` — one feature module each (crm, billing, …).
- `derpixler/skolva` — the product: a thin composition root that assembles
  Core + chosen modules into a single binary.

**Why not a monorepo?** A standalone Core repo makes it a first-class open-core
product that other projects can depend on without pulling the entire Skolva
codebase. Module repositories ship and version independently. The cost is
weaker local cross-repo ergonomics (mitigated by a local `go.work`).

## Decision 2: Compile-time assembly, one binary

Modules are **Go packages that implement `module.Module`.** The product `main`
imports Core and the desired modules, registers them in a `Registry`, and
builds a single static binary.

No microservices, no dynamic Go plugins. This keeps deployment trivial while
the modular contract ensures clean boundaries. Should a module ever need to
become a separate service, the event bus seam makes the transition possible
without rewriting.

## Decision 3: One dependency rule

```
module → skolva-core (only)
module → module  (forbidden)
```

Every module imports `skolva-core` and nothing else. Cross-module interaction
goes through the `events.Bus` / hooks and **soft references** (store an ID; no
cross-module foreign keys). This is the property that makes modules
independently extractable, testable and reusable.

## Decision 4: Pluggable infra seams

For every cross-cutting infrastructure concern, Core defines an **interface + a
secure, performant default.** No adapter is built until a real use-case demands
it.

| Seam | Interface | Default |
|---|---|---|
| Event bus | `events.Bus` | In-process (hooks) |
| Cache | `cache.Cache` | In-memory, TTL |
| Search | `search.Service` | Postgres FTS (German) |
| Jobs | River (Postgres) | Queued via `jobs.Worker` |

This is the opposite of "let's add Redis just in case." The seam is cheap to
define now; the adapter is expensive to build and maintain. Add it when you
know you need it.

## Decision 5: Per-module schema ownership

Modules own their tables as versioned `Migration` objects (tracked by
`module.Registry.Migrate` in a central `schema_migrations` table, keyed by
`(module, version)`). No central `schema.sql` that all modules share. Core
provides the shared base (functions, extensions, audit, EAV) that module
migrations assume has already run.

The full split of the legacy monolithic schema happens **at extraction time**
for each module — premature earlier because tables for not-yet-extracted
modules still need to exist in the product.

## Decision 6: Identity provider seam

Authentication is decomposed into three independent concerns that stay
separate:

- **Token verification** — `middleware.Verifier` (injectable; local HS256
  today, OIDC/JWKS later).
- **Login provider** — `auth.Provider` (local password login today; OIDC
  redirect later). Each provider mounts its own login routes; no forced
  `Authenticate(email, password)` method.
- **Authorization (RBAC)** — `RequirePermission` / service `CheckPermission`,
  always local (permissions are resolved from the seeded roles regardless of
  how the user authenticated).

## Consequences

- **Core is a clean, reusable, open foundation.** Other products can `go get`
  it and start building.
- **Modules evolve and ship independently.** A breaking change in Core means
  bump the version in each module and the product — a coordination cost that
  is manageable with discipline and low module count.
- **Seams keep enterprise infrastructure reachable** without paying for it a
  day before you need it.
- **Module independence is verified by the build:** no import path crosses
  module boundaries except via Core.
