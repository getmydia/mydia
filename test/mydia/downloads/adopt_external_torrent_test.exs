defmodule Mydia.Downloads.AdoptExternalTorrentTest do
  use Mydia.DataCase, async: true
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Downloads
  alias Mydia.Downloads.Structs.ExternalTorrent
  alias Mydia.Jobs.MediaImport

  import Mydia.MediaFixtures

  defp torrent(overrides \\ %{}) do
    struct!(
      %ExternalTorrent{
        id: "abc123",
        client_name: "qbit",
        client_id: "hash-a",
        title: "The.Bear.S03E02.1080p.WEB-DL.x264-GROUP",
        kind: :needs_matching,
        size: 2_000_000,
        save_path: "/downloads/the-bear"
      },
      overrides
    )
  end

  test "creates a tracked download pointing at the chosen media item" do
    show = media_item_fixture(%{type: "tv_show"})

    assert {:ok, download} = Downloads.adopt_external_torrent(torrent(), show.id)

    assert download.media_item_id == show.id
    assert download.download_client == "qbit"
    assert download.download_client_id == "hash-a"
    assert download.indexer == "manual"
    # Nothing special about it from here on: it looks like any grabbed download.
    assert is_nil(download.match_status)
  end

  test "enqueues the import job with the torrent's save path" do
    show = media_item_fixture(%{type: "tv_show"})

    {:ok, download} = Downloads.adopt_external_torrent(torrent(), show.id)

    assert_enqueued(
      worker: MediaImport,
      args: %{"download_id" => download.id, "save_path" => "/downloads/the-bear"}
    )
  end

  test "accepts an episode id" do
    episode = episode_fixture()

    {:ok, download} =
      Downloads.adopt_external_torrent(torrent(), episode.media_item_id, episode.id)

    assert download.episode_id == episode.id
  end

  test "reports already_tracked when the same torrent was adopted twice" do
    show = media_item_fixture(%{type: "tv_show"})
    {:ok, _first} = Downloads.adopt_external_torrent(torrent(), show.id)

    assert {:error, :already_tracked} = Downloads.adopt_external_torrent(torrent(), show.id)
  end
end
