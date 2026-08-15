defmodule Mydia.Repo.Migrations.MbaRemovalTest do
  # async: false - this test queries outside the usual schema layer.
  use Mydia.DataCase, async: false

  alias Mydia.Library.MediaFile
  alias Mydia.Repo
  alias Mydia.Settings
  alias Mydia.Settings.LibraryPath

  # The migration has already run by the time the test database exists, so
  # these assertions describe the post-migration world.

  test "the twelve MBA tables no longer exist" do
    for table <- ~w(playlist_tracks music_files playlists tracks albums artists
                    book_files books authors adult_files scenes studios) do
      assert {:error, _} = Repo.query(~s(SELECT 1 FROM "#{table}" LIMIT 1))
    end
  end

  test "library_paths rejects the removed type values" do
    assert {:error, changeset} =
             Settings.create_library_path(%{path: "/media/music", type: :music})

    refute changeset.valid?
  end

  describe "library_path conversion" do
    test "converting a library path does not delete its media files" do
      # Proves the invariant the migration relies on: flipping type and disabled
      # on a library_paths row leaves media_files untouched. The regression this
      # guards is media_files.library_path_id being on_delete: :delete_all, which
      # would cascade if the migration deleted the row instead of converting it.
      {:ok, path} = Settings.create_library_path(%{path: "/media/mixed", type: :mixed})

      {:ok, _file} =
        %MediaFile{}
        |> MediaFile.scan_changeset(%{relative_path: "a.mkv", library_path_id: path.id})
        |> Repo.insert()

      before_count = Repo.aggregate(MediaFile, :count)

      # The same write the migration performs, driven through Ecto so it stays
      # adapter-neutral here. The migration's raw statement, boolean literal and
      # all, runs end to end against a real 'music' row in
      # archive_and_drop_mba_tables_test.exs.
      path
      |> Ecto.Changeset.change(%{type: :mixed, disabled: true})
      |> Repo.update!()

      # The row was converted rather than removed, and nothing followed it out.
      assert Repo.get!(LibraryPath, path.id).disabled
      assert Repo.aggregate(MediaFile, :count) == before_count
    end
  end
end
