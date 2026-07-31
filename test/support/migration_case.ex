defmodule Mydia.MigrationCase do
  @moduledoc """
  Case template for tests that run a migration against a populated database.

  Every test using this must be tagged `@tag :tmp_dir`; the temp directory is
  where the throwaway SQLite database lives.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Mydia.MigrationCase
    end
  end

  setup tags do
    tmp_dir =
      tags[:tmp_dir] ||
        raise "Mydia.MigrationCase requires @tag :tmp_dir on every test"

    database = Path.join(tmp_dir, "migration_test.db")

    start_supervised!(
      {Mydia.MigrationTestRepo, database: database, pool_size: 1, foreign_keys: :on}
    )

    {:ok, repo: Mydia.MigrationTestRepo, database: database}
  end

  @doc """
  Run a statement against the migration test repo and return the result struct.
  """
  def sql!(query, params \\ []) do
    Mydia.MigrationTestRepo.query!(query, params)
  end

  @doc """
  Run a migration module's `up/0` against the migration test repo.

  `version` only has to be unique within a single test's database.
  """
  def run_migration!(module, version) do
    Ecto.Migrator.up(Mydia.MigrationTestRepo, version, module, log: false)
  end
end
