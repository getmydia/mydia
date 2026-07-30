defmodule Mydia.Repo.Migrations.DropScanIntervalSqliteDefault do
  use Ecto.Migration
  import Mydia.Repo.Migrations.Helpers

  @moduledoc """
  Drops the leftover SQLite column DEFAULT 3600 on library_paths.scan_interval.

  The PostgreSQL default was dropped in 20260730153426_make_scan_interval_opt_in.exs,
  which assumed the SQLite one was unreachable because Ecto would always send the
  field explicitly. That assumption is wrong: Ecto omits a field from an INSERT when
  its cast value equals the struct's value (nil == nil for a new record), and a
  struct insert omits nil fields too. The column default therefore won, silently
  persisting 3600 and enabling hourly scanning on paths nobody opted in.

  SQLite cannot ALTER COLUMN ... DROP DEFAULT, but it has supported per-column
  DROP COLUMN since 3.35, so add / copy / drop / rename is enough. A full table
  rebuild is deliberately avoided: it would have to reproduce all 20 columns, the
  CHECK constraints, and the foreign keys, and any omission is silent data loss.
  """

  def up do
    unless postgres?() do
      execute "ALTER TABLE library_paths ADD COLUMN scan_interval_new INTEGER"
      execute "UPDATE library_paths SET scan_interval_new = scan_interval"
      execute "ALTER TABLE library_paths DROP COLUMN scan_interval"
      execute "ALTER TABLE library_paths RENAME COLUMN scan_interval_new TO scan_interval"
    end
  end

  def down do
    # The prior default cannot be restored without a full table rebuild, and
    # restoring it would reintroduce the bug this migration fixes.
    :ok
  end
end
