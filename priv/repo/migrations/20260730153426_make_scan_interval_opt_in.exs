defmodule Mydia.Repo.Migrations.MakeScanIntervalOptIn do
  use Ecto.Migration
  import Mydia.Repo.Migrations.Helpers

  @moduledoc """
  Automatic library scanning becomes opt-in per path.

  `scan_interval` now means "scan every N seconds", and NULL means "manual only".
  Every existing row is NULLed because no instance has ever had automatic scanning:
  `Mydia.Jobs.LibraryScanner` has not been in the crontab since 2025-11-20 (03df95b5),
  so NULLing preserves current behavior rather than changing it.

  No table rebuild is needed. The column is already nullable on both adapters, so only
  the DB-level DEFAULT has to go, and `ALTER COLUMN ... DROP DEFAULT` is PostgreSQL-only.

  This migration deliberately leaves the SQLite default in place, and that was a mistake.
  It assumed the leftover default was unreachable because Ecto always sends
  schema-declared fields explicitly. Ecto does not: it omits a field from an INSERT when
  its cast value equals the struct's current value, which is true of a freshly built
  `%LibraryPath{}` whose `scan_interval` is nil, and a plain struct insert omits nil
  fields for the same reason. The SQLite default therefore won, and new library paths
  silently persisted 3600 instead of "manual only".

  `20260730160558_drop_scan_interval_sqlite_default.exs` fixes that by dropping the
  SQLite default for real. Read the two together; this one is not sufficient on its own.
  """

  def up do
    execute "UPDATE library_paths SET scan_interval = NULL"

    if postgres?() do
      execute "ALTER TABLE library_paths ALTER COLUMN scan_interval DROP DEFAULT"
    end
  end

  def down do
    if postgres?() do
      execute "ALTER TABLE library_paths ALTER COLUMN scan_interval SET DEFAULT 3600"
    end

    execute "UPDATE library_paths SET scan_interval = 3600 WHERE scan_interval IS NULL"
  end
end
