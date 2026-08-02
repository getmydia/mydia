defmodule Mydia.MigrationTestRepo do
  @moduledoc """
  Throwaway repo for migration tests.

  Migration tests need real DDL against a real database file. The SQL sandbox
  wraps each test in a transaction it later rolls back, which conflicts with
  `Ecto.Migrator` opening its own transaction and writing `schema_migrations`.
  This repo is started per test against a temporary SQLite file instead, so a
  migration test can never touch `Mydia.Repo`.

  It is deliberately always SQLite, even when the suite runs against
  PostgreSQL, because the behavior under test is SQLite-specific.
  """
  use Ecto.Repo,
    otp_app: :mydia,
    adapter: Ecto.Adapters.SQLite3
end
