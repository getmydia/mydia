defmodule Mydia.Repo.Migrations.BackfillExcludedSourcesTest do
  use Mydia.DataCase, async: false

  alias Mydia.Settings
  alias Mydia.Settings.QualityProfile

  @cam_tier ["CAM", "Telesync", "Telecine", "Screener", "Workprint"]

  # Deliberately NOT the numeric timestamp from the migration filename
  # (20260804182323). The `test` mix alias runs `ecto.migrate --quiet` before
  # ExUnit starts, which already applies that real version to the persistent
  # test database. Calling Ecto.Migrator.up/4 again with that same version
  # would see it in `schema_migrations` and short-circuit to `:already_up`
  # without invoking `up/0` at all. A version far outside the range any real
  # migration will ever use keeps this test's bookkeeping row confined to the
  # sandboxed transaction for the current test, which rolls back on exit.
  @migration_version 20_991_231_235_959

  # Migration modules are not compiled into the app (priv/repo/migrations is
  # not in elixirc_paths), so load the file explicitly before referencing it.
  Code.require_file("priv/repo/migrations/20260804182323_backfill_excluded_sources.exs")

  describe "shipped profile definitions" do
    test "every default profile excludes cam-tier out of the box" do
      for profile <- Mydia.Settings.DefaultQualityProfiles.defaults() do
        excluded = get_in(profile, [:quality_standards, :excluded_sources]) || []

        assert Enum.sort(excluded) == Enum.sort(@cam_tier),
               "#{profile.name} must ship with the cam-tier exclusion"
      end
    end
  end

  describe "backfill behavior" do
    # Driving Ecto.Migrator.up/4 against the DataCase-sandboxed Mydia.Repo
    # deadlocks under PostgreSQL: Migrator takes the migration lock on the
    # connection the test process already holds via the sandbox, then spawns
    # a Task to run the migration body inside its own repo.transaction/2,
    # which needs a *second* concurrent connection. The sandbox virtualizes
    # every checkout to the single connection the test process is already
    # blocked holding, so the Task's checkout times out
    # (DBConnection.ConnectionError). This is a property of
    # Ecto.Migrator + Ecto.Adapters.SQL.Sandbox on Postgres, independent of
    # what the migration does - it reproduces with a no-op migration too, and
    # matches the reasoning documented on Mydia.MigrationTestRepo for why that
    # helper never touches Mydia.Repo. SQLite does not hit this because its
    # migrator path does not take the same lock+Task detour.
    #
    # The migration's actual behavior is still verified on both engines: this
    # describe block covers it on SQLite (the default `mix test` adapter),
    # and `mix ecto.migrate` was run directly against a real PostgreSQL
    # database as part of this change (see the task report) to confirm the
    # backfill applies cleanly there too.
    @describetag skip:
                   Mydia.DB.postgres?() and
                     "Ecto.Migrator.up/4 deadlocks the SQL sandbox on Postgres (see comment); verified separately via mix ecto.migrate"

    test "adds the exclusion without losing other standards" do
      {:ok, profile} =
        Settings.create_quality_profile(%{
          name: "Legacy Profile",
          quality_standards: %{
            preferred_resolutions: ["1080p"],
            min_resolution: "1080p",
            preferred_sources: ["BluRay", "WEB-DL"]
          }
        })

      run_migration_up()

      reloaded = Repo.get!(QualityProfile, profile.id)
      assert Enum.sort(reloaded.quality_standards.excluded_sources) == Enum.sort(@cam_tier)
      # pre-existing keys survive
      assert reloaded.quality_standards.min_resolution == "1080p"
      assert reloaded.quality_standards.preferred_sources == ["BluRay", "WEB-DL"]
    end

    test "never overwrites a deliberate choice" do
      {:ok, profile} =
        Settings.create_quality_profile(%{
          name: "Deliberately Permissive",
          quality_standards: %{preferred_resolutions: ["1080p"], excluded_sources: []}
        })

      run_migration_up()

      reloaded = Repo.get!(QualityProfile, profile.id)

      assert reloaded.quality_standards.excluded_sources == [],
             "an operator who cleared the list must keep it cleared"
    end

    test "is idempotent across repeated runs" do
      {:ok, profile} =
        Settings.create_quality_profile(%{
          name: "Idempotent",
          quality_standards: %{preferred_resolutions: ["720p"], min_resolution: "720p"}
        })

      run_migration_up()
      first = Repo.get!(QualityProfile, profile.id).quality_standards

      run_migration_up()
      second = Repo.get!(QualityProfile, profile.id).quality_standards

      assert first == second
    end
  end

  # Invokes the migration's own up/0 through the real Ecto migrator, rather
  # than a test helper that copies the migration's per-row logic: a test that
  # duplicates the code under test cannot catch a mistake in that code.
  #
  # Ecto.Migration.Runner.run/7 (as documented in older Ecto releases) does not
  # match the installed Ecto 3.14.1, which takes an extra `config` argument
  # (run/8) and is private API not meant to be driven directly from a test.
  # Ecto.Migrator.up/4 is the public entry point and works against the
  # DataCase-managed sandbox connection for Mydia.Repo.
  defp run_migration_up do
    Ecto.Migrator.up(Repo, @migration_version, Mydia.Repo.Migrations.BackfillExcludedSources,
      log: false
    )
  end
end
