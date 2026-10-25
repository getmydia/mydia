defmodule Mydia.Downloads.Queue.DuplicatesTest do
  @moduledoc """
  `blocking_downloads/2` (the manual search modal's view of what blocks a grab)
  and `check_for_active_download/4` (the click-time guard) share one query.

  download_fixture/1 uses download_client: "test-client", which has no
  registered client config, so client verification treats the row as active.
  """
  use Mydia.DataCase, async: false

  import Ecto.Query

  alias Mydia.Downloads
  alias Mydia.Downloads.Download
  alias Mydia.Downloads.Queue.Duplicates
  alias Mydia.Indexers.SearchResult
  alias Mydia.Indexers.Structs.SearchResultMetadata

  import Mydia.MediaFixtures
  import Mydia.DownloadsFixtures

  defp search_result(metadata) do
    %SearchResult{
      download_url: "magnet:?xt=urn:btih:req-#{System.unique_integer([:positive])}",
      title: "Requested Release",
      indexer: "test",
      size: 1_000_000_000,
      seeders: 10,
      leechers: 5,
      metadata: metadata
    }
  end

  defp ids(downloads), do: Enum.map(downloads, & &1.id)

  describe "episode context" do
    test "an occupying episode download is listed and blocks the grab" do
      show = media_item_fixture(%{type: "tv_show"})
      episode = episode_fixture(%{media_item_id: show.id})
      download = download_fixture(%{media_item_id: show.id, episode_id: episode.id})
      context = %{type: :episode, episode_id: episode.id}

      assert ids(Downloads.blocking_downloads(show, context)) == [download.id]

      assert Duplicates.check_for_active_download(search_result(nil), show.id, episode.id) ==
               {:error, :duplicate_download}
    end

    test "an active season pack does not appear for an episode context" do
      show = media_item_fixture(%{type: "tv_show"})
      episode = episode_fixture(%{media_item_id: show.id})

      download_fixture(%{
        media_item_id: show.id,
        metadata: %{season_pack: true, season_number: 1}
      })

      context = %{type: :episode, episode_id: episode.id}

      assert Downloads.blocking_downloads(show, context) == []
      assert Duplicates.check_for_active_download(search_result(nil), show.id, episode.id) == :ok
    end

    test "a failed or imported download is not listed" do
      show = media_item_fixture(%{type: "tv_show"})
      episode = episode_fixture(%{media_item_id: show.id})

      download_fixture(%{
        media_item_id: show.id,
        episode_id: episode.id,
        error_message: "boom"
      })

      download_fixture(%{
        media_item_id: show.id,
        episode_id: episode.id,
        imported_at: DateTime.utc_now()
      })

      context = %{type: :episode, episode_id: episode.id}

      assert Downloads.blocking_downloads(show, context) == []
      assert Duplicates.check_for_active_download(search_result(nil), show.id, episode.id) == :ok
    end

    test "results are ordered oldest first" do
      show = media_item_fixture(%{type: "tv_show"})
      episode = episode_fixture(%{media_item_id: show.id})
      first = download_fixture(%{media_item_id: show.id, episode_id: episode.id})
      second = download_fixture(%{media_item_id: show.id, episode_id: episode.id})

      older = DateTime.add(DateTime.utc_now(), -3600, :second)

      Mydia.Repo.update_all(from(d in Download, where: d.id == ^second.id),
        set: [inserted_at: older]
      )

      context = %{type: :episode, episode_id: episode.id}

      assert ids(Downloads.blocking_downloads(show, context)) == [second.id, first.id]
    end
  end

  describe "season context" do
    test "an occupying season pack is listed and blocks the grab" do
      show = media_item_fixture(%{type: "tv_show"})

      download =
        download_fixture(%{
          media_item_id: show.id,
          metadata: %{season_pack: true, season_number: 2}
        })

      context = %{type: :season, season_number: 2}
      pack = search_result(%SearchResultMetadata{season_pack: true, season_number: 2})

      assert ids(Downloads.blocking_downloads(show, context)) == [download.id]

      assert Duplicates.check_for_active_download(pack, show.id, nil) ==
               {:error, :duplicate_download}
    end

    test "a pack for another season is not listed" do
      show = media_item_fixture(%{type: "tv_show"})

      download_fixture(%{
        media_item_id: show.id,
        metadata: %{season_pack: true, season_number: 2}
      })

      context = %{type: :season, season_number: 3}
      pack = search_result(%SearchResultMetadata{season_pack: true, season_number: 3})

      assert Downloads.blocking_downloads(show, context) == []
      assert Duplicates.check_for_active_download(pack, show.id, nil) == :ok
    end
  end

  describe "movie" do
    test "an occupying movie download is listed and blocks the grab" do
      movie = media_item_fixture(%{type: "movie"})
      download = download_fixture(%{media_item_id: movie.id})

      assert ids(Downloads.blocking_downloads(movie, nil)) == [download.id]

      assert Duplicates.check_for_active_download(search_result(nil), movie.id, nil) ==
               {:error, :duplicate_download}
    end

    test "a failed movie download is not listed" do
      movie = media_item_fixture(%{type: "movie"})
      download_fixture(%{media_item_id: movie.id, error_message: "boom"})

      assert Downloads.blocking_downloads(movie, nil) == []
    end
  end

  describe "whole-show context" do
    test "returns [] because that grab dedupes by release URL" do
      show = media_item_fixture(%{type: "tv_show"})
      download_fixture(%{media_item_id: show.id, metadata: %{}})

      assert Downloads.blocking_downloads(show, nil) == []
      assert Downloads.blocking_downloads(show, %{type: :show}) == []
    end
  end
end
