defmodule Mydia.Repo.Migrations.BackfillImportGroupsTest do
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library.ImportGroup
  alias Mydia.Repo

  @moduledoc false

  # The migration delegates to the context, so this exercises the same call the
  # migration makes rather than running the migration itself. Running a real
  # migration inside the sandbox is what MigrationCase is for, and it cannot see
  # sandbox-created rows.
  test "backfills a group per series folder and is safe to run twice" do
    lp = library_path_fixture(%{type: "series", path: "/media/Series"})

    for n <- 1..4 do
      orphaned_media_file_fixture(%{
        library_path_id: lp.id,
        relative_path: "Pin-Pon (1996)/Season 01/ep#{n}.mkv"
      })
    end

    assert {:ok, %{groups: 1, files: 4}} = Mydia.ImportGroups.upsert_for_library(lp)
    assert {:ok, %{groups: 1, files: 4}} = Mydia.ImportGroups.upsert_for_library(lp)

    assert Repo.aggregate(ImportGroup, :count) == 1
    assert Repo.one!(ImportGroup).file_count == 4
  end

  describe "up/0 and down/0 via the real migrator" do
    # Ecto.Migrator.up/4 against the DataCase-sandboxed Mydia.Repo deadlocks
    # under PostgreSQL: it takes the migration lock on the connection the test
    # process already holds via the sandbox, then spawns a Task to run the
    # migration body inside its own repo.transaction/2, which needs a
    # *second* concurrent connection the sandbox cannot provide. This is a
    # property of Ecto.Migrator + Ecto.Adapters.SQL.Sandbox on Postgres,
    # independent of what the migration does — see
    # backfill_excluded_sources_test.exs for the full writeup and its own
    # confirmation that a no-op migration reproduces it too. SQLite does not
    # hit this because its migrator path does not take the same lock+Task
    # detour.
    #
    # Mydia.MigrationTestRepo (a second, unsandboxed connection built for
    # exactly this deadlock) is not an option here: both this migration and
    # Mydia.ImportGroups.upsert_for_library/2 hardcode Mydia.Repo, so a
    # throwaway repo would silently run against the real connection and see
    # none of this test's sandboxed fixture rows.
    #
    # The migration's actual up/0 and down/0 behavior is still verified on
    # both engines: this describe block covers SQLite (the default `mix test`
    # adapter), and the migrate/rollback/re-migrate cycle was run directly
    # against a real PostgreSQL database with seeded data as part of this
    # change (see the task report) to confirm both engines behave the same
    # way outside the sandbox.
    @describetag skip:
                   Mydia.DB.postgres?() and
                     "Ecto.Migrator.up/4 deadlocks the SQL sandbox on Postgres (see comment); verified separately via mix ecto.migrate"

    # Deliberately not the real migration's timestamp (20260817143638). The
    # `test` mix alias runs `ecto.migrate --quiet` before ExUnit starts, which
    # already applies that real version to the persistent test database.
    # Calling Ecto.Migrator.up/4 again with that same version would see it in
    # `schema_migrations` and short-circuit to `:already_up` without invoking
    # `up/0` at all. A version far outside the range any real migration will
    # ever use keeps this test's bookkeeping row confined to the sandboxed
    # transaction for the current test, which rolls back on exit.
    @migration_version 20_991_231_235_958

    # Migration modules are not compiled into the app (priv/repo/migrations is
    # not in elixirc_paths). `ecto.migrate --quiet` (run by the `test` alias
    # before ExUnit starts) already required this exact file once against the
    # persistent test database, so guard against requiring it again — that
    # would redefine the module with a warning.
    unless Code.ensure_loaded?(Mydia.Repo.Migrations.BackfillImportGroups) do
      Code.require_file("priv/repo/migrations/20260817143638_backfill_import_groups.exs")
    end

    test "up/0 creates a group and stamps members; down/0 is a no-op that leaves them" do
      lp = library_path_fixture(%{type: "series", path: "/media/Migrator"})

      files =
        for n <- 1..3 do
          orphaned_media_file_fixture(%{
            library_path_id: lp.id,
            relative_path: "Some Show (2020)/Season 01/ep#{n}.mkv"
          })
        end

      run_migration_up()

      group = Repo.one!(ImportGroup)
      assert group.library_path_id == lp.id
      assert group.file_count == 3

      for file <- files do
        assert Repo.reload!(file).import_group_id == group.id
      end

      # down/0 is deliberately a no-op: by the time anyone rolls this back,
      # groups carry live human decisions (accepted, ignored, local shows)
      # that a blanket DELETE would destroy alongside the backfill. Rolling
      # back must not touch what up/0 created.
      run_migration_down()

      assert Repo.aggregate(ImportGroup, :count) == 1

      for file <- files do
        assert Repo.reload!(file).import_group_id == group.id
      end
    end

    # Invokes the migration's own up/0 and down/0 through the real migrator,
    # rather than a test helper that copies the raw-query logic: a test that
    # duplicates the code under test cannot catch a mistake in that code (the
    # raw `from(lp in "library_paths", ...)` query and the down/0 SQL are
    # exercised by nothing else).
    defp run_migration_up do
      Ecto.Migrator.up(
        Repo,
        @migration_version,
        Mydia.Repo.Migrations.BackfillImportGroups,
        log: false
      )
    end

    defp run_migration_down do
      Ecto.Migrator.down(
        Repo,
        @migration_version,
        Mydia.Repo.Migrations.BackfillImportGroups,
        log: false
      )
    end
  end
end
