defmodule Mydia.Downloads.RejectReleaseTest do
  use Mydia.DataCase, async: true
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Downloads
  alias Mydia.Downloads.Blacklists
  alias Mydia.Repo

  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures

  describe "reject_release/2" do
    test "blacklists the release, deletes the row, and queues a fresh search" do
      media_item = media_item_fixture(%{type: "tv_show"})

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          indexer: "1337x",
          metadata: %{"guid" => "https://1337x.to/torrent/6314993/"}
        })

      assert {:ok, :rejected} = Downloads.reject_release(download)

      assert Blacklists.blacklisted?("1337x", "https://1337x.to/torrent/6314993/")
      refute Repo.get(Mydia.Downloads.Download, download.id)

      assert_enqueued(
        worker: Mydia.Jobs.TVShowSearch,
        args: %{"mode" => "show", "media_item_id" => media_item.id}
      )
    end

    test "queues a specific episode search when the download is bound to an episode" do
      media_item = media_item_fixture(%{type: "tv_show"})
      episode = episode_fixture(%{media_item_id: media_item.id})

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          episode_id: episode.id,
          indexer: "1337x",
          metadata: %{"guid" => "abc"}
        })

      assert {:ok, :rejected} = Downloads.reject_release(download)

      assert_enqueued(
        worker: Mydia.Jobs.TVShowSearch,
        args: %{"mode" => "specific", "episode_id" => episode.id}
      )
    end

    test "queues a movie search for a movie download" do
      media_item = media_item_fixture(%{type: "movie"})

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          indexer: "1337x",
          metadata: %{"guid" => "abc"}
        })

      assert {:ok, :rejected} = Downloads.reject_release(download)

      assert_enqueued(
        worker: Mydia.Jobs.MovieSearch,
        args: %{"mode" => "specific", "media_item_id" => media_item.id}
      )
    end

    test "refuses and changes nothing when the guid is missing" do
      download = download_fixture(%{indexer: "1337x", metadata: %{}})

      assert {:error, :no_guid} = Downloads.reject_release(download)
      assert Repo.get(Mydia.Downloads.Download, download.id)
    end

    test "refuses and changes nothing when the indexer is missing" do
      download = download_fixture(%{indexer: nil, metadata: %{"guid" => "abc"}})

      assert {:error, :no_indexer} = Downloads.reject_release(download)
      assert Repo.get(Mydia.Downloads.Download, download.id)
    end

    # Ordering-adjacent coverage: extract_key/1 and Blacklists.add/4 are the
    # gate a real order-inversion bug would still have to pass through
    # (neither has any way to fail given the inputs reject_release/2 always
    # supplies — see the fix report for why a genuine Blacklists.add/4
    # failure can't be forced here without mocking). This proves the
    # blacklist-then-delete sequence completes correctly even when the
    # optional search step is a no-op, so nothing downstream of the gate is
    # silently skipped or reordered around a missing media item.
    test "still blacklists and deletes the row when there is no media item to search for" do
      download =
        download_fixture(%{
          media_item_id: nil,
          indexer: "1337x",
          metadata: %{"guid" => "no-media-item-guid"}
        })

      assert {:ok, :rejected} = Downloads.reject_release(download)

      assert Blacklists.blacklisted?("1337x", "no-media-item-guid")
      refute Repo.get(Mydia.Downloads.Download, download.id)
      refute_enqueued(worker: Mydia.Jobs.TVShowSearch)
      refute_enqueued(worker: Mydia.Jobs.MovieSearch)
    end
  end
end
