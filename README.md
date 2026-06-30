# Skolva Core

**The reusable, battle-tested foundation for building modular server
applications — powering the [Skolva](https://github.com/derpixler/skolva)
community-management platform and ready for your product too.**

Apache-2.0 licensed.

---

## Why

Every Go backend starts with the same plumbing — authentication, middleware,
database pools, secrets, email, search, background jobs. You copy it, tweak it,
maintain it. And when you need cross-module communication, you either tightly
couple packages or reach for a message broker prematurely.

**Core gives you all of that, ready to go, with a contract your features plug
into.** You implement `module.Module`, register it, and focus on your domain
logic — not on rewriting `verifyToken` for the fourth time.

- **Battle-tested** — powers Skolva's identity, CRM and groups modules; the
  same code that runs in production, open for any project.
- **Modular from the start** — every feature is a module. Modules never import
  each other; they talk through the event bus and soft references. Swap, remove
  or extract a module without touching the rest.
- **No lock-in** — infra seams (`events`, `cache`, `search`, `jobs`) ship with
  in-process and Postgres defaults. Wire Redis, RabbitMQ or Elasticsearch
  **later** by implementing one interface. You design the seam, not the
  machine.

```go
go get github.com/derpixler/skolva-core@v0.1.0
```

## What's inside

### Module SDK — `module`
The contract every feature implements: `Name / Version / Permissions /
Migrations / RegisterHooks / RegisterRoutes / OpenAPISpec / Activate /
Deactivate`. A `Registry` mounts routes, aggregates permissions, runs
versioned per-module migrations (idempotent, tracked in `schema_migrations`),
and drives the module lifecycle. Typed `Deps` bundle so modules ask for
capabilities, not concrete wiring.

### Pluggable infra seams
| Seam | Default | Future adapter |
|---|---|---|
| `events.Bus` | In-process (hooks) | Redis Streams, NATS, RabbitMQ |
| `cache.Cache` | In-memory (TTL, clock-injectable) | Redis |
| `search.Service` | Postgres FTS (German) | Elasticsearch, OpenSearch |
| `jobs` (River) | Postgres-backed worker | abstracted when needed |

### Identity primitives
- `middleware` — JWT verification (injectable — swap local HS256 for OIDC/JWKS
  when ready), RBAC (`RequirePermission` with admin wildcard), `ActorMiddleware`,
  CORS, RequestID.
- `secrets` — AES-256-GCM cipher (SHA-256 key derivation, any passphrase).
- `metadata` — EAV key/value store (validated tables, eg. `users_meta`).

### Platform foundation
- `config` / `database` (dual pgx pools) / `dbexec` (actor-gated audit transactions
  with soft-delete enforcement) / `errors` (HTTP-status-mapped) / `mail` (SMTP +
  NoopMailer + HTML templates) / `types` (decimal, duration) / `ai` (provider
  interface, noop default).

## Quickstart

```go
// 1. Implement the contract
type billingModule struct{}

func (b *billingModule) Name() string { return "billing" }
func (b *billingModule) Version() string { return "0.1.0" }
func (b *billingModule) Permissions() []module.Permission {
    return []module.Permission{{Slug: "billing.read", Description: "View invoices"}}
}
func (b *billingModule) Migrations() []module.Migration {
    return []module.Migration{{Version: 1, Name: "invoices", SQL: `CREATE TABLE invoices...`}}
}
func (b *billingModule) RegisterHooks(hm *hooks.HookManager) error { return nil }
func (b *billingModule) RegisterRoutes(api *gin.RouterGroup, d module.Deps) {
    api.GET("/billing", myHandler(d.DB))
}
func (b *billingModule) OpenAPISpec() []byte { return nil }
func (b *billingModule) Activate(ctx context.Context, d module.Deps) error { return nil }
func (b *billingModule) Deactivate(ctx context.Context) error { return nil }

// 2. Assemble
registry := module.NewRegistry(billingModule{})
deps := module.Deps{
    DB:     pool,
    Mailer: mail.NewNoopMailer(),
    Events: events.NewInProc(hookManager),
    Cache:  cache.NewMemory(),
    Search: search.NewService(pool),
    // ...
}

// 3. Lifecycle
registry.Migrate(ctx, pool)          // runs your migrations (idempotent)
registry.RegisterHooks(hookManager)
registry.MountRoutes(api, deps)
registry.ActivateAll(ctx, deps)
// on shutdown: registry.DeactivateAll(ctx)
```

## Architecture

1. **One dependency.** Every module depends on `skolva-core`. **Never on another
   module.** Cross-module interaction goes through the event bus + soft
   references (store IDs, no cross-module foreign keys).
2. **Own your schema.** Each module ships its own versioned migrations. Core's
   runner applies them in registration order, skips already-applied ones.
3. **Compile-time assembly, one binary.** The product main imports Core + the
   modules it wants, registers them, and builds.
4. **Infra stays swappable.** The `Bus` / `Cache` / `Service` interfaces are
   the contract. Start with in-process and Postgres; swap when you actually
   need Redis or Elasticsearch.
5. **Module repos are autonomous.** When a module grows, it can be extracted
   into its own repository (`skolva-<name>`) and published independently.
   The consuming product just updates a `go.mod require`.

## Status

`v0.x` — the SDK surface (especially `module.Module` and `module.Deps`) may
evolve before `v1`. The infrastructure packages (`config`, `database`,
`middleware`, `secrets`, ...) are stable in practice.

## More

- [Module Charter](docs/module-charter.md) — the full rules for modules, with
  a concrete example.
- [Architecture decision](docs/architecture.md) — the rationale behind the
  polyrepo, open-core design.
- [Getting started](docs/getting-started.md) — step-by-step from `go get` to a
  working module.
- [Skolva product](https://github.com/derpixler/skolva) — the community
  management platform built on Core.
