# Getting Started

A step-by-step guide from an empty directory to a module that registers with
Core, owns its database schema and mounts HTTP routes.

## 1. Create a new Go module

```bash
mkdir myproject && cd myproject
go mod init github.com/you/myproject
```

## 2. Add the Core dependency

```bash
go get github.com/derpixler/skolva-core@v0.1.0
```

## 3. Implement `module.Module`

Create a file `internal/mymodule/module.go`:

```go
package mymodule

import (
    "context"

    "github.com/derpixler/skolva-core/hooks"
    "github.com/derpixler/skolva-core/module"
    "github.com/gin-gonic/gin"
)

type mod struct{}

// Module exposes the feature for assembly.
func Module() module.Module { return &mod{} }

func (m *mod) Name() string                    { return "mymodule" }
func (m *mod) Version() string                 { return "0.1.0" }
func (m *mod) Permissions() []module.Permission { return nil }
func (m *mod) Migrations() []module.Migration   { return nil }
func (m *mod) RegisterHooks(*hooks.HookManager) error { return nil }
func (m *mod) RegisterRoutes(api *gin.RouterGroup, d module.Deps) {
    api.GET("/hello", func(c *gin.Context) { c.String(200, "Hello, Core!") })
}
func (m *mod) OpenAPISpec() []byte { return nil }
func (m *mod) Activate(context.Context, module.Deps) error { return nil }
func (m *mod) Deactivate(context.Context) error { return nil }
```

## 4. Give it a migration

Add a table the module owns:

```go
func (m *mod) Migrations() []module.Migration {
    return []module.Migration{
        {Version: 1, Name: "create_items", SQL: `
            CREATE TABLE items (
                id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
                name TEXT NOT NULL
            )
        `},
    }
}
```

## 5. Assemble the application

In `cmd/server/main.go`:

```go
package main

import (
    "context"
    "log/slog"
    "os"

    "github.com/you/myproject/internal/mymodule"
    "github.com/derpixler/skolva-core/cache"
    "github.com/derpixler/skolva-core/database"
    "github.com/derpixler/skolva-core/events"
    "github.com/derpixler/skolva-core/hooks"
    "github.com/derpixler/skolva-core/mail"
    "github.com/derpixler/skolva-core/module"
    "github.com/derpixler/skolva-core/search"
    "github.com/gin-gonic/gin"
)

func main() {
    ctx := context.Background()
    pool, _ := database.NewPools(ctx, os.Getenv("DATABASE_URL"))
    defer pool.Close()

    hookManager := hooks.NewHookManager()
    deps := module.Deps{
        DB:     pool.Web,
        Hooks:  hookManager,
        Mailer: mail.NewNoopMailer(),
        Events: events.NewInProc(hookManager),
        Cache:  cache.NewMemory(),
        Search: search.NewService(pool.Web),
        Logger: slog.Default(),
    }

    registry := module.NewRegistry(mymodule.Module())

    // Run per-module migrations (idempotent)
    if err := registry.Migrate(ctx, pool.Web); err != nil { panic(err) }
    if err := registry.RegisterHooks(hookManager); err != nil { panic(err) }
    if err := registry.ActivateAll(ctx, deps); err != nil { panic(err) }

    router := gin.New()
    api := router.Group("/api")
    registry.MountRoutes(api, deps)

    router.Run(":8080")
}
```

## 6. Test with testcontainers

```go
func TestMigrations(t *testing.T) {
    // spin up a postgres:16-alpine container via testcontainers-go
    pool := startPostgres(t)   // helper omitted for brevity

    r := module.NewRegistry(mymodule.Module())

    // migrations create the items table
    if err := r.Migrate(context.Background(), pool); err != nil {
        t.Fatalf("migrate: %v", err)
    }

    // verify the table exists
    var count int
    pool.QueryRow(context.Background(),
        `SELECT count(*) FROM information_schema.tables WHERE table_name='items'`,
    ).Scan(&count)
    if count != 1 { t.Error("migration did not create the items table") }

    // re-run is a no-op
    if err := r.Migrate(context.Background(), pool); err != nil {
        t.Errorf("re-run: %v", err)
    }
}
```

Docker must be running for container-based tests. Unit tests that don't touch
the database can skip the container.

## What's next

- Add more modules and register them in the registry — they stay independent.
- Return real `Permissions()` so RBAC gates protect your routes.
- Return your module's OpenAPI fragment via `OpenAPISpec()`.
- Subscribe to events via `RegisterHooks` to react across module boundaries.
- Use the `events.Bus` and `cache.Cache` from `Deps` for cross-cutting
  concerns.
- When the module is stable, extract it into its own repository (see the
  [Module Charter](module-charter.md)).
