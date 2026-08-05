defmodule Mydia.Downloads.GrabberTest do
  use Mydia.DataCase, async: false

  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Downloads
  alias Mydia.Downloads.Download
  alias Mydia.Downloads.Grabber
  alias Mydia.Indexers.SearchResult
  alias Mydia.Repo

  setup do
    Phoenix.PubSub.subscribe(Mydia.PubSub, "downloads")
    :ok
  end

  defp search_result(overrides \\ %{}) do
    struct!(
      %SearchResult{
        title: "Some.Movie.2020.1080p.BluRay",
        indexer: "test-indexer",
        download_url: "magnet:?xt=urn:btih:" <> String.duplicate("c", 40),
        size: 1_000_000,
        seeders: 10,
        leechers: 2,
        quality: "1080p",
        download_protocol: :torrent
      },
      overrides
    )
  end

  describe "grab_async/2" do
    test "inserts a client-less record immediately and reports failure via PubSub when no client exists" do
      movie = media_item_fixture(%{type: "movie"})

      assert {:ok, %Download{} = download} =
               Downloads.grab_async(search_result(), media_item_id: movie.id, manual: true)

      # The synchronous part never assigns a client.
      assert is_nil(download.download_client)
      assert is_nil(download.download_client_id)
      assert download.media_item_id == movie.id

      assert download.metadata["indexer"] == "test-indexer" or
               download.metadata[:indexer] == "test-indexer"

      # No download clients configured -> the background task fails the grab.
      assert_receive {:grab_failed, %{download_id: download_id, reason: reason}}, 2_000
      assert download_id == download.id
      assert reason =~ "client"

      reloaded = Repo.get!(Download, download.id)
      assert reloaded.error_message == reason
    end

    test "removes the optimistic record when the background task can't be started" do
      movie = media_item_fixture(%{type: "movie"})

      # A supervisor that refuses every child, so start_child/2 returns
      # {:error, :max_children} instead of {:ok, pid}.
      full_supervisor = start_supervised!({Task.Supervisor, max_children: 0})

      assert {:error, {:task_start_failed, :max_children}} =
               Downloads.grab_async(search_result(),
                 media_item_id: movie.id,
                 manual: true,
                 supervisor: full_supervisor
               )

      # Nothing left behind to occupy the target and block a re-grab.
      assert Repo.all(Download) == []
    end
  end

  describe "run_grab/3 — duplicate" do
    test "deletes the optimistic record and broadcasts grab_duplicate" do
      movie = media_item_fixture(%{type: "movie"})
      _existing = download_fixture(media_item_id: movie.id)

      sr = search_result()

      {:ok, optimistic} =
        Downloads.create_download(%{
          title: sr.title,
          indexer: sr.indexer,
          download_url: sr.download_url,
          media_item_id: movie.id
        })

      assert :duplicate =
               Grabber.run_grab(optimistic, sr, media_item_id: movie.id, manual: true)

      assert Repo.get(Download, optimistic.id) == nil
      assert_receive {:grab_duplicate, %{download_url: url, reason: :duplicate_download}}
      assert url == sr.download_url
    end

    test "carries :already_have_files when files on disk are the blocker" do
      # No in-flight download here. The movie already has a media file and the
      # grab is not manual, so the existing-files check is what rejects it.
      # Subscribers need the two cases apart: one means wait, the other means
      # there is nothing to wait for.
      movie = media_item_fixture(%{type: "movie"})
      media_file_fixture(%{media_item_id: movie.id})

      sr = search_result()

      {:ok, optimistic} =
        Downloads.create_download(%{
          title: sr.title,
          indexer: sr.indexer,
          download_url: sr.download_url,
          media_item_id: movie.id
        })

      assert :duplicate = Grabber.run_grab(optimistic, sr, media_item_id: movie.id)

      assert Repo.get(Download, optimistic.id) == nil
      assert_receive {:grab_duplicate, %{reason: :already_have_files}}
    end
  end

  describe "run_grab/3 — success via blackhole client" do
    @tag :tmp_dir
    test "assigns client fields and broadcasts grab_completed", %{tmp_dir: tmp_dir} do
      Mydia.Downloads.register_clients()

      watch = Path.join(tmp_dir, "watch")
      completed = Path.join(tmp_dir, "completed")
      File.mkdir_p!(watch)
      File.mkdir_p!(completed)

      client =
        download_client_config_fixture(%{
          type: "blackhole",
          connection_settings: %{
            "watch_folder" => watch,
            "completed_folder" => completed
          }
        })

      movie = media_item_fixture(%{type: "movie"})
      sr = search_result()

      {:ok, optimistic} =
        Downloads.create_download(%{
          title: sr.title,
          indexer: sr.indexer,
          download_url: sr.download_url,
          media_item_id: movie.id
        })

      assert :ok = Grabber.run_grab(optimistic, sr, media_item_id: movie.id, manual: true)

      reloaded = Repo.get!(Download, optimistic.id)
      assert reloaded.download_client == client.name
      assert is_binary(reloaded.download_client_id)

      assert_receive {:grab_completed, %{download_id: download_id}}
      assert download_id == optimistic.id
    end
  end
end
