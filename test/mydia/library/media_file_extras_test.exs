defmodule Mydia.Library.MediaFileExtrasTest do
  use Mydia.DataCase, async: true

  alias Mydia.Library.MediaFile
  alias Mydia.Repo

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  defp file_attrs(library_path, overrides) do
    Enum.into(overrides, %{
      media_item_id: media_item_fixture().id,
      library_path_id: library_path.id,
      relative_path: "Movie (2007)/#{System.unique_integer([:positive])}.mkv"
    })
  end

  defp insert_file(library_path, overrides) do
    %MediaFile{}
    |> MediaFile.changeset(file_attrs(library_path, overrides))
    |> Repo.insert!()
  end

  describe "extra classification fields" do
    test "changeset casts the three extra fields" do
      library_path = library_path_fixture()

      file =
        insert_file(library_path, %{
          extra_kind: :deleted_scene,
          extra_source: :duration,
          extra_checked_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert file.extra_kind == :deleted_scene
      assert file.extra_source == :duration
      assert file.extra_checked_at
    end

    test "scan_changeset casts the three extra fields" do
      library_path = library_path_fixture()

      changeset =
        MediaFile.scan_changeset(
          %MediaFile{},
          file_attrs(library_path, %{extra_kind: :trailer, extra_source: :filename})
        )

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :extra_kind) == :trailer
      assert Ecto.Changeset.get_change(changeset, :extra_source) == :filename
    end

    test "extra_kind defaults to nil, meaning the file is a version" do
      library_path = library_path_fixture()
      file = insert_file(library_path, %{})

      assert is_nil(file.extra_kind)
      assert is_nil(file.extra_source)
      assert is_nil(file.extra_checked_at)
    end
  end

  describe "versions/0 and active/0" do
    setup do
      library_path = library_path_fixture()

      version = insert_file(library_path, %{})
      extra = insert_file(library_path, %{extra_kind: :featurette, extra_source: :duration})

      trashed =
        insert_file(library_path, %{
          trashed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      %{version: version, extra: extra, trashed: trashed}
    end

    test "active/0 excludes trashed but keeps extras", ctx do
      ids = MediaFile.active() |> Repo.all() |> Enum.map(& &1.id) |> MapSet.new()

      assert MapSet.member?(ids, ctx.version.id)
      assert MapSet.member?(ids, ctx.extra.id)
      refute MapSet.member?(ids, ctx.trashed.id)
    end

    test "versions/0 excludes both trashed and extras", ctx do
      ids = MediaFile.versions() |> Repo.all() |> Enum.map(& &1.id) |> MapSet.new()

      assert MapSet.member?(ids, ctx.version.id)
      refute MapSet.member?(ids, ctx.extra.id)
      refute MapSet.member?(ids, ctx.trashed.id)
    end
  end
end
