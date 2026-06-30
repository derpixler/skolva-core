# Module Charter

The rules every Skolva module follows, and the recipe for creating a new one.
These rules are also captured for the agent workflow in the
`skolva-module-charter` skill.

## The 12 Rules

1. **Naming.** Repository `derpixler/skolva-<name>`; Go module path
   `github.com/derpixler/skolva-<name>`.
2. **One dependency.** `require github.com/derpixler/skolva-core` — nothing
   else. Never import another `skolva-<module>`.
3. **Cross-module talk via Core.** The `events.Bus`, `hooks.HookManager` and
   **soft references** (store a UUID, no cross-module foreign key) are the
   only inter-module channels.
4. **Implement `module.Module`.** Expose a public constructor (`Module()` /
   `New(…)`) that returns the interface. The full surface: `Name`, `Version`,
   `Permissions`, `Migrations`, `RegisterHooks`, `RegisterRoutes`,
   `OpenAPISpec`, `Activate`, `Deactivate`.
5. **Own your schema.** Migrations are versioned, ordered SQL strings returned
   by `Migrations()`. The module runner applies them idempotently, per module,
   in registration order. Core's base (functions, extensions, audit, EAV) is
   assumed to have run first.
6. **Register your permissions.** Return them via `Permissions()` — do not
   hardcode RBAC entries in a central schema.
7. **OpenAPI fragment.** Return your spec via `OpenAPISpec()`; the product
   composes all fragments into the served spec.
8. **SemVer per repo.** Root tags `vX.Y.Z`. Pin a compatible `skolva-core`
   version in `go.mod`.
9. **Apache-2.0 license** (unless explicitly decided otherwise per module).
10. **Tests with testcontainers.** Bootstrap the test database from Core+module
    migrations rather than a monolithic `schema.sql`. Reuse the gated
    detail-logging convention (`tstep`/`tlog`/`assertStatus`, `-v`-only).
11. **CI per repo** — building and testing against the pinned Core version.
12. **Product integration.** Register in the product's `app.DefaultRegistry`,
    add to `go.mod require`, compose OpenAPI, wire into deployment.

## Minimal Example

```go
package mymodule

import (
    "context"
    "github.com/derpixler/skolva-core/hooks"
    "github.com/derpixler/skolva-core/module"
    "github.com/gin-gonic/gin"
)

type mod struct{}

// Module returns the mymodule feature as a module.Module.
func Module() module.Module { return &mod{} }

func (m *mod) Name() string    { return "mymodule" }
func (m *mod) Version() string { return "0.1.0" }

// Permissions are added to the global RBAC catalog.
func (m *mod) Permissions() []module.Permission {
    return []module.Permission{{Slug: "mymodule.read", Description: "View data"}}
}

// Migrations run once, idempotently, in version order.
func (m *mod) Migrations() []module.Migration {
    return []module.Migration{
        {Version: 1, Name: "create_table", SQL: `CREATE TABLE ...`},
        {Version: 2, Name: "add_index", SQL: `CREATE INDEX ...`},
    }
}

func (m *mod) RegisterHooks(hm *hooks.HookManager) error { return nil }

func (m *mod) RegisterRoutes(api *gin.RouterGroup, d module.Deps) {
    api.GET("/mymodule", func(c *gin.Context) { /* ... */ })
}

func (m *mod) OpenAPISpec() []byte { return nil }

func (m *mod) Activate(ctx context.Context, d module.Deps) error {
    // Initialisation: start background goroutines, cache warmup, …
    return nil
}
func (m *mod) Deactivate(ctx context.Context) error {
    // Graceful teardown.
    return nil
}
```

## Extracting a module to its own repository

1. Ensure the module is fully decoupled in-place (own migrations, no
   cross-module imports, only talks via events and soft references).
2. History-preserving split with `git filter-repo` into the new
   `derpixler/skolva-<name>` repo.
3. Set module path (`github.com/derpixler/skolva-<name>`), `go.mod require
   skolva-core`, Apache-2.0 LICENSE, CI workflow, tag `v0.1.0`.
4. In the consuming product, replace the in-tree package with the published
   module version and slim the product accordingly.
5. Repo creation, pushes and board changes are public actions — present the
   exact steps for approval before executing.

## Creating a module (in-place, before its own repo exists)

Add a `Module()` adapter in the product's package tree, implement the
contract, register it in `app.DefaultRegistry`, give it per-module migrations
and a proof test that bootstraps from `Registry.Migrate`. Keep the build
green at every step.
