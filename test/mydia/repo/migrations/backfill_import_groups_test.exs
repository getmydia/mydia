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
end
