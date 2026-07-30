defmodule Mydia.Repo.Migrations.MakeScanIntervalOptIn do
  use Ecto.Migration
  import Mydia.Repo.Migrations.Helpers

  @moduledoc """
  Automatic library scanning becomes opt-in per path.

  `scan_interval` now means "scan every N seconds", and NULL means "manual only".
  Every existing row is NULLed because no instance has ever had automatic scanning:
  `Mydia.Jobs.LibraryScanner` has not been in the crontab since 2025-11-20 (03df95b5),
  so NULLing preserves current behavior rather than changing it.

  No table rebuild is needed. The column is already nullable on both adapters; only the
  DB-level DEFAULT has to go, and that is PostgreSQL-only. On SQLite the leftover default
  is unreachable, because it applies only to INSERTs that omit the column and Ecto always
  sends schema-declared fields explicitly.
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
