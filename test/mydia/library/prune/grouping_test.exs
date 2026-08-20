defmodule Mydia.Library.Prune.GroupingTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library.Prune.Grouping

  describe "list_groups/0" do
    test "returns an episode holding two active files" do
      show = media_item_fixture(%{type: "tv_show"})
      episode = episode_fixture(%{media_item_id: show.id})
      lp = library_path_fixture(%{type: "series"})

      a = media_file_fixture(%{episode_id: episode.id, library_path_id: lp.id})
      b = media_file_fixture(%{episode_id: episode.id, library_path_id: lp.id})

      assert [group] = Grouping.list_groups()
      assert group.subject_type == :episode
      assert group.subject_id == episode.id
      assert group.media_item.id == show.id
      assert Enum.map(group.files, & &1.id) |> Enum.sort() == Enum.sort([a.id, b.id])
    end

    test "returns a movie holding two active files" do
      movie = media_item_fixture(%{type: "movie"})
      lp = library_path_fixture(%{type: "movies"})

      media_file_fixture(%{media_item_id: movie.id, library_path_id: lp.id})
      media_file_fixture(%{media_item_id: movie.id, library_path_id: lp.id})

      assert [group] = Grouping.list_groups()
      assert group.subject_type == :movie
      assert group.subject_id == movie.id
      assert length(group.files) == 2
    end

    test "ignores items with exactly one file" do
      movie = media_item_fixture(%{type: "movie"})
      media_file_fixture(%{media_item_id: movie.id})

      assert Grouping.list_groups() == []
    end

    test "ignores trashed files when counting" do
      movie = media_item_fixture(%{type: "movie"})
      media_file_fixture(%{media_item_id: movie.id})
      keep = media_file_fixture(%{media_item_id: movie.id})

      {:ok, _} = Mydia.Library.trash_media_file(keep)

      assert Grouping.list_groups() == []
    end

    test "preloads library_path so absolute_path resolves" do
      movie = media_item_fixture(%{type: "movie"})
      media_file_fixture(%{media_item_id: movie.id})
      media_file_fixture(%{media_item_id: movie.id})

      assert [group] = Grouping.list_groups()

      for file <- group.files do
        assert is_binary(Mydia.Library.MediaFile.absolute_path(file))
      end
    end
  end
end
