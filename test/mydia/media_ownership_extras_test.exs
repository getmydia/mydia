defmodule Mydia.MediaOwnershipExtrasTest do
  use Mydia.DataCase, async: false

  alias Mydia.Library.MediaFile
  alias Mydia.Media
  alias Mydia.Repo

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  defp insert_file(item, library_path, name, overrides) do
    attrs =
      Enum.into(overrides, %{
        media_item_id: item.id,
        library_path_id: library_path.id,
        relative_path: "Movie (2007)/#{name}"
      })

    %MediaFile{} |> MediaFile.changeset(attrs) |> Repo.insert!()
  end

  defp owned?(item) do
    Media.list_library_items_page([])
    |> Enum.find(&(&1.id == item.id))
    |> Map.fetch!(:owned)
  end

  test "a movie whose only file is an extra is not reported as owned" do
    library_path = library_path_fixture(%{type: "movies"})
    item = media_item_fixture(%{type: "movie"})

    insert_file(item, library_path, "deleted-scene.mkv", %{
      extra_kind: :deleted_scene,
      extra_source: :folder
    })

    refute owned?(item), "an extras-only folder must not make the movie look downloaded"
  end

  test "a movie with a real file is still reported as owned" do
    library_path = library_path_fixture(%{type: "movies"})
    item = media_item_fixture(%{type: "movie"})

    insert_file(item, library_path, "Movie.2007.1080p.mkv", %{})

    assert owned?(item)
  end

  test "get_media_files_for_item/2 hides extras by default" do
    library_path = library_path_fixture(%{type: "movies"})
    item = media_item_fixture(%{type: "movie"})

    feature = insert_file(item, library_path, "Movie.2007.1080p.mkv", %{})

    extra =
      insert_file(item, library_path, "scene.mkv", %{extra_kind: :other, extra_source: :duration})

    ids = item.id |> Mydia.Library.get_media_files_for_item() |> Enum.map(& &1.id)
    assert ids == [feature.id]

    all_ids =
      item.id
      |> Mydia.Library.get_media_files_for_item(include_extras: true)
      |> Enum.map(& &1.id)
      |> MapSet.new()

    assert MapSet.equal?(all_ids, MapSet.new([feature.id, extra.id]))
  end
end
