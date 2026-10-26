defmodule Mydia.Repo.Migrations.FoldBdripIntoBlurayTest do
  use Mydia.DataCase, async: false

  import Ecto.Query

  alias Mydia.Settings
  alias Mydia.Settings.QualityProfile

  # Not the filename's timestamp: `mix test` has already applied that version,
  # so Ecto.Migrator.up/4 would short-circuit to :already_up. See
  # backfill_excluded_sources_test.exs for the full reasoning.
  @migration_version 20_991_231_235_958

  Code.require_file(
    "priv/repo/migrations/20261025170251_fold_bdrip_into_bluray_in_quality_profiles.exs"
  )

  # Ecto.Migrator.up/4 deadlocks the SQL sandbox on Postgres; the same skip
  # and reasoning as backfill_excluded_sources_test.exs.
  @moduletag skip:
               Mydia.DB.postgres?() and
                 "Ecto.Migrator.up/4 deadlocks the SQL sandbox on Postgres (see backfill_excluded_sources_test.exs)"

  test "folds preferences to BluRay, drops exclusions, keeps other standards" do
    profile =
      legacy_profile("Legacy BDRip", %{
        "preferred_resolutions" => ["1080p"],
        "min_resolution" => "720p",
        "preferred_sources" => ["BDRip", "BluRay", "WEB-DL", "BRRip"],
        "excluded_sources" => ["BRRip", "CAM"]
      })

    run_migration_up()

    standards = Repo.get!(QualityProfile, profile.id).quality_standards
    assert standards.preferred_sources == ["BluRay", "WEB-DL"]
    assert standards.excluded_sources == ["CAM"]
    assert standards.min_resolution == "720p"
  end

  test "leaves rows that list neither name byte-for-byte untouched" do
    # A duplicate the fold would collapse, to prove the row is skipped rather
    # than rewritten to an equal value.
    raw = ~s({"preferred_resolutions":["1080p"],"preferred_sources":["BluRay","BluRay"]})
    profile = legacy_profile("Untouched", raw)

    run_migration_up()

    assert raw_standards(profile.id) == raw
  end

  test "is idempotent" do
    profile =
      legacy_profile("Twice", %{
        "preferred_resolutions" => ["1080p"],
        "preferred_sources" => ["BDRip"]
      })

    run_migration_up()
    first = raw_standards(profile.id)

    run_migration_up()
    assert raw_standards(profile.id) == first
    assert Repo.get!(QualityProfile, profile.id).quality_standards.preferred_sources == ["BluRay"]
  end

  # The changeset now folds BDRip on save, so a legacy row has to be written
  # around it, the way rows from before the fold sit in the table.
  defp legacy_profile(name, standards) do
    {:ok, profile} =
      Settings.create_quality_profile(%{
        name: name,
        quality_standards: %{preferred_resolutions: ["1080p"]}
      })

    raw = if is_binary(standards), do: standards, else: Jason.encode!(standards)

    {1, _} =
      Repo.update_all(from(p in "quality_profiles", where: p.id == type(^profile.id, :binary_id)),
        set: [quality_standards: raw]
      )

    profile
  end

  defp raw_standards(id) do
    Repo.one!(
      from(p in "quality_profiles",
        where: p.id == type(^id, :binary_id),
        select: p.quality_standards
      )
    )
  end

  defp run_migration_up do
    Ecto.Migrator.up(
      Repo,
      @migration_version,
      Mydia.Repo.Migrations.FoldBdripIntoBlurayInQualityProfiles,
      log: false
    )
  end
end
