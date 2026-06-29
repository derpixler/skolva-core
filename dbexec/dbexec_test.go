package dbexec_test

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/derpixler/skolva-core/dbexec"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/testcontainers/testcontainers-go"
	"github.com/testcontainers/testcontainers-go/modules/postgres"
	"github.com/testcontainers/testcontainers-go/wait"
)

const insertUser = `INSERT INTO users (email, password_hash, first_name, last_name)
VALUES ($1, $2, 'Test', 'User') RETURNING id`

func newSchemaPool(t *testing.T) (*pgxpool.Pool, func()) {
	t.Helper()

	if os.Getenv("SKIP_INTEGRATION") == "1" {
		t.Skip("skipping integration test")
	}

	ctx := context.Background()

	pgContainer, err := postgres.Run(ctx,
		"postgres:16-alpine",
		postgres.WithDatabase("vv"),
		postgres.WithUsername("vv"),
		postgres.WithPassword("vv"),
		testcontainers.WithWaitStrategy(
			wait.ForLog("database system is ready to accept connections").
				WithOccurrence(2).
				WithStartupTimeout(30*time.Second),
		),
	)
	if err != nil {
		t.Fatalf("failed to start postgres container: %v", err)
	}

	connStr, err := pgContainer.ConnectionString(ctx, "sslmode=disable")
	if err != nil {
		t.Fatalf("failed to get connection string: %v", err)
	}

	pool, err := pgxpool.New(ctx, connStr)
	if err != nil {
		t.Fatalf("failed to create pool: %v", err)
	}

	if _, err := pool.Exec(ctx, `
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE OR REPLACE FUNCTION prevent_permanent_delete()
RETURNS TRIGGER AS $$
BEGIN
  IF COALESCE(current_setting('app.allow_delete', true), '') = '1' THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'physical DELETE on % is forbidden', TG_TABLE_NAME;
END;
$$ LANGUAGE plpgsql;

CREATE TABLE users (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  email TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  first_name TEXT NOT NULL,
  last_name TEXT NOT NULL,
  deleted_at TIMESTAMPTZ
);

CREATE TABLE audit_logs (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  table_name TEXT NOT NULL,
  record_pk TEXT NOT NULL,
  action TEXT NOT NULL,
  old_data JSONB,
  new_data JSONB,
  actor_user_id UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION audit_trigger_func()
RETURNS TRIGGER AS $$
DECLARE
  actor UUID;
BEGIN
  actor := NULLIF(current_setting('app.actor_user_id', true), '')::UUID;
  IF TG_OP = 'INSERT' THEN
    INSERT INTO audit_logs (table_name, record_pk, action, new_data, actor_user_id)
    VALUES (TG_TABLE_NAME, NEW.id::TEXT, 'INSERT', to_jsonb(NEW), actor);
    RETURN NEW;
  ELSIF TG_OP = 'UPDATE' THEN
    INSERT INTO audit_logs (table_name, record_pk, action, old_data, new_data, actor_user_id)
    VALUES (TG_TABLE_NAME, NEW.id::TEXT, 'UPDATE', to_jsonb(OLD), to_jsonb(NEW), actor);
    RETURN NEW;
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tr_users_block_delete
BEFORE DELETE ON users FOR EACH ROW EXECUTE PROCEDURE prevent_permanent_delete();
CREATE TRIGGER tr_users_audit
AFTER INSERT OR UPDATE ON users FOR EACH ROW EXECUTE PROCEDURE audit_trigger_func();
`); err != nil {
		t.Fatalf("failed to apply test schema: %v", err)
	}

	cleanup := func() {
		pool.Close()
		if err := pgContainer.Terminate(ctx); err != nil {
			t.Logf("failed to terminate container: %v", err)
		}
	}
	return pool, cleanup
}

func TestWithActor(t *testing.T) {
	pool, cleanup := newSchemaPool(t)
	defer cleanup()
	ctx := context.Background()

	var actorID uuid.UUID
	if err := pool.QueryRow(ctx, insertUser, "actor@example.com", "hash").Scan(&actorID); err != nil {
		t.Fatalf("insert actor: %v", err)
	}

	// Commit path: subject is created and tagged with the actor in audit_logs.
	var subjectID uuid.UUID
	err := dbexec.WithActor(ctx, pool, actorID, func(ctx context.Context, tx pgx.Tx) error {
		return tx.QueryRow(ctx, insertUser, "subject@example.com", "hash").Scan(&subjectID)
	})
	if err != nil {
		t.Fatalf("WithActor commit: %v", err)
	}

	var cnt int
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM users WHERE id=$1", subjectID).Scan(&cnt); err != nil {
		t.Fatalf("count subject: %v", err)
	}
	if cnt != 1 {
		t.Fatalf("expected subject committed, got count=%d", cnt)
	}

	var auditActor uuid.UUID
	err = pool.QueryRow(ctx,
		"SELECT actor_user_id FROM audit_logs WHERE table_name='users' AND record_pk=$1 AND action='INSERT'",
		subjectID.String()).Scan(&auditActor)
	if err != nil {
		t.Fatalf("query audit log: %v", err)
	}
	if auditActor != actorID {
		t.Errorf("expected audit actor %s, got %s", actorID, auditActor)
	}

	// Rollback path: fn error rolls back the inserted row.
	sentinel := errors.New("boom")
	err = dbexec.WithActor(ctx, pool, actorID, func(ctx context.Context, tx pgx.Tx) error {
		if _, e := tx.Exec(ctx, insertUser, "rollback@example.com", "hash"); e != nil {
			return e
		}
		return sentinel
	})
	if !errors.Is(err, sentinel) {
		t.Fatalf("expected sentinel error, got %v", err)
	}
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM users WHERE email=$1", "rollback@example.com").Scan(&cnt); err != nil {
		t.Fatalf("count rollback: %v", err)
	}
	if cnt != 0 {
		t.Errorf("expected rollback (count=0), got %d", cnt)
	}
}

func TestAllowDelete(t *testing.T) {
	pool, cleanup := newSchemaPool(t)
	defer cleanup()
	ctx := context.Background()

	var uid uuid.UUID
	if err := pool.QueryRow(ctx, insertUser, "victim@example.com", "hash").Scan(&uid); err != nil {
		t.Fatalf("insert victim: %v", err)
	}

	// Physical delete is blocked without AllowDelete.
	err := dbexec.WithActor(ctx, pool, uuid.Nil, func(ctx context.Context, tx pgx.Tx) error {
		_, e := tx.Exec(ctx, "DELETE FROM users WHERE id=$1", uid)
		return e
	})
	if err == nil {
		t.Fatal("expected physical delete to be blocked")
	}

	var cnt int
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM users WHERE id=$1", uid).Scan(&cnt); err != nil {
		t.Fatalf("count after blocked delete: %v", err)
	}
	if cnt != 1 {
		t.Fatalf("expected user still present, got count=%d", cnt)
	}

	// Physical delete succeeds with AllowDelete.
	err = dbexec.WithActorOptions(ctx, pool, uuid.Nil, dbexec.Options{AllowDelete: true}, func(ctx context.Context, tx pgx.Tx) error {
		_, e := tx.Exec(ctx, "DELETE FROM users WHERE id=$1", uid)
		return e
	})
	if err != nil {
		t.Fatalf("WithActorOptions allow-delete: %v", err)
	}

	if err := pool.QueryRow(ctx, "SELECT count(*) FROM users WHERE id=$1", uid).Scan(&cnt); err != nil {
		t.Fatalf("count after allowed delete: %v", err)
	}
	if cnt != 0 {
		t.Errorf("expected user deleted, got count=%d", cnt)
	}
}
