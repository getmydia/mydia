defmodule Mydia.Media.DeletionClientTorrentsTest do
  # Deleting a media item cascades its download rows away, so the client has
  # to be told in the same breath or its torrents strand in Issues (#1422).
  use Mydia.DataCase, async: true
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Accounts.Scope
  alias Mydia.Jobs.RemoveClientTorrent
  alias Mydia.Media

  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures

  defp download!(attrs) do
    download_fixture(Map.merge(%{download_client: "qbit", download_client_id: "hash-a"}, attrs))
  end

  test "deleting a movie removes its torrent from the client, keeping the data" do
    movie = media_item_fixture(%{type: "movie", title: "Fictional Lantern Bay"})
    download!(%{media_item_id: movie.id})

    {:ok, _deleted, _disk} = Media.delete_media_item(Scope.unrestricted(), movie)

    assert_enqueued(
      worker: RemoveClientTorrent,
      args: %{"client" => "qbit", "client_id" => "hash-a", "delete_files" => false}
    )
  end

  test "deleting with files also deletes the torrent's data" do
    movie = media_item_fixture(%{type: "movie", title: "Fictional Lantern Bay"})
    download!(%{media_item_id: movie.id})

    {:ok, _deleted, _disk} =
      Media.delete_media_item(Scope.unrestricted(), movie, delete_files: true)

    assert_enqueued(
      worker: RemoveClientTorrent,
      args: %{"client" => "qbit", "client_id" => "hash-a", "delete_files" => true}
    )
  end

  test "a show's episode downloads are removed too" do
    episode = episode_fixture()
    show = Mydia.Repo.get!(Mydia.Media.MediaItem, episode.media_item_id)
    download!(%{media_item_id: nil, episode_id: episode.id, download_client_id: "hash-ep"})

    {:ok, _deleted, _disk} = Media.delete_media_item(Scope.unrestricted(), show)

    assert_enqueued(worker: RemoveClientTorrent, args: %{"client_id" => "hash-ep"})
  end

  test "bulk deletion removes every item's torrents" do
    one = media_item_fixture(%{type: "movie", title: "Fictional Copper Field"})
    two = media_item_fixture(%{type: "movie", title: "Fictional Glass Ridge"})
    download!(%{media_item_id: one.id, download_client_id: "hash-1"})
    download!(%{media_item_id: two.id, download_client_id: "hash-2"})

    {:ok, 2, _disk} = Media.delete_media_items(Scope.unrestricted(), [one.id, two.id])

    assert_enqueued(worker: RemoveClientTorrent, args: %{"client_id" => "hash-1"})
    assert_enqueued(worker: RemoveClientTorrent, args: %{"client_id" => "hash-2"})
  end

  # Clear Completed deletes the download row but can leave the torrent
  # seeding; only the imported file's provenance still names it.
  test "a torrent known only from an imported file's provenance is removed too" do
    movie = media_item_fixture(%{type: "movie", title: "Fictional Lantern Bay"})

    media_file_fixture(%{
      media_item_id: movie.id,
      metadata: %{"download_client" => "qbit", "download_client_id" => "hash-cleared"}
    })

    {:ok, _deleted, _disk} = Media.delete_media_item(Scope.unrestricted(), movie)

    assert_enqueued(worker: RemoveClientTorrent, args: %{"client_id" => "hash-cleared"})
  end

  test "the job leaves a torrent Mydia tracks again alone" do
    movie = media_item_fixture(%{type: "movie", title: "Fictional Copper Field"})
    # Adopted for another item after the delete enqueued the removal.
    download!(%{media_item_id: movie.id, download_client_id: "hash-adopted"})
    # A configured client nothing listens on: a removal attempt would error.
    Mydia.SettingsFixtures.download_client_config_fixture(%{name: "qbit", port: 1})

    assert :ok =
             perform_job(RemoveClientTorrent, %{
               "client" => "qbit",
               "client_id" => "hash-adopted",
               "delete_files" => true
             })

    assert Mydia.Repo.get_by(Mydia.Downloads.Download, download_client_id: "hash-adopted")
  end

  test "a download no client holds enqueues nothing" do
    movie = media_item_fixture(%{type: "movie", title: "Fictional Lantern Bay"})
    download!(%{media_item_id: movie.id, download_client: nil, download_client_id: nil})

    {:ok, _deleted, _disk} = Media.delete_media_item(Scope.unrestricted(), movie)

    refute_enqueued(worker: RemoveClientTorrent)
  end

  test "the job treats a client that is gone as done" do
    assert :ok =
             perform_job(RemoveClientTorrent, %{
               "client" => "no-such-client",
               "client_id" => "hash-a",
               "delete_files" => false
             })
  end
end
