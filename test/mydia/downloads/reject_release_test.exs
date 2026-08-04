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
  end
end
