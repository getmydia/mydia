defmodule Mydia.Downloads.Queue.UndoOrphanAddTest do
  @moduledoc """
  A grab adds the torrent to the client before its download row is saved. When
  that save fails (the item was deleted mid-grab, most often), the torrent must
  not stay in the client untracked: the add is undone, data included. A torrent
  another download row already tracked before the add is left alone.

  `async: false`: the runtime config and the adapter registry are global.
  """
  use Mydia.DataCase, async: false

  import ExUnit.CaptureLog
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Downloads.{Download, Grabber, History, Queue}
  alias Mydia.Downloads.Client.{Error, Registry}
  alias Mydia.Indexers.SearchResult

  @client "orphan-client"
  @client_id "orphan-hash"

  defmodule RecordingAdapter do
    @behaviour Mydia.Downloads.Client

    defp notify(msg), do: send(:persistent_term.get({__MODULE__, :pid}), msg)

    # A test can run `{__MODULE__, :on_add}` inside the add, to delete the item
    # in the window between the add and the save of its row.
    @impl true
    def add_torrent(_config, _torrent, _opts) do
      notify(:added)
      :persistent_term.get({__MODULE__, :on_add}, fn -> :ok end).()
      {:ok, "orphan-hash"}
    end

    @impl true
    def remove_torrent(_config, client_id, opts) do
      :persistent_term.get({__MODULE__, :on_remove}, fn -> :ok end).()
      notify({:removed, client_id, opts})
      :ok
    end

    @impl true
    def supported_protocols, do: [:torrent]
    @impl true
    def test_connection(_config), do: {:ok, %{version: "1.0.0", api_version: "1.0"}}
    @impl true
    def get_status(_config, _client_id), do: {:error, Error.not_found("missing")}
    @impl true
    def list_torrents(_config, _opts), do: {:ok, []}
    @impl true
    def pause_torrent(_config, _client_id), do: :ok
    @impl true
    def resume_torrent(_config, _client_id), do: :ok
  end

  setup do
    setup_runtime_config()
    :persistent_term.put({RecordingAdapter, :pid}, self())
    previous = Registry.lookup(:transmission)
    Registry.register(:transmission, RecordingAdapter)

    on_exit(fn ->
      :persistent_term.erase({RecordingAdapter, :pid})
      :persistent_term.erase({RecordingAdapter, :on_add})
      :persistent_term.erase({RecordingAdapter, :on_remove})

      if previous,
        do: Registry.register(:transmission, previous),
        else: Registry.unregister(:transmission)
    end)

    download_client_config_fixture(%{name: @client, type: "transmission"})
    :ok
  end

  describe "initiate_download/2" do
    test "refuses a grab for a deleted item before touching the client" do
      show = media_item_fixture(%{type: "tv_show", title: "The Hollow Orchard"})
      episode = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 3})
      Repo.delete!(show)

      capture_log(fn ->
        assert {:error, :media_item_deleted} =
                 Queue.initiate_download(result(),
                   media_item_id: show.id,
                   episode_id: episode.id
                 )
      end)

      refute_received :added
      refute Repo.exists?(Download)
    end

    test "removes the just-added torrent and its data when the item goes during the add" do
      show = media_item_fixture(%{type: "tv_show", title: "The Hollow Orchard"})
      episode = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 3})
      :persistent_term.put({RecordingAdapter, :on_add}, fn -> Repo.delete!(show) end)

      capture_log(fn ->
        assert {:error, %Ecto.Changeset{}} =
                 Queue.initiate_download(result(),
                   media_item_id: show.id,
                   episode_id: episode.id
                 )
      end)

      assert_received {:removed, @client_id, opts}
      assert opts[:delete_files] == true
      refute Repo.exists?(Download)
    end

    test "keeps a torrent another download row tracked before the add" do
      owner = media_item_fixture(%{type: "movie", title: "The Paper Lighthouse"})

      {:ok, _row} =
        History.create_download(%{
          title: "The.Paper.Lighthouse.1080p",
          media_item_id: owner.id,
          download_client: @client,
          download_client_id: @client_id
        })

      gone = media_item_fixture(%{type: "movie", title: "The Glass Meadow"})
      :persistent_term.put({RecordingAdapter, :on_add}, fn -> Repo.delete!(gone) end)

      capture_log(fn ->
        assert {:error, _reason} = Queue.initiate_download(result(), media_item_id: gone.id)
      end)

      refute_received {:removed, _, _}
    end

    test "does not touch the client when the record saves" do
      movie = media_item_fixture(%{type: "movie", title: "The Copper Harbor"})

      capture_log(fn ->
        assert {:ok, %Download{}} = Queue.initiate_download(result(), media_item_id: movie.id)
      end)

      refute_received {:removed, _, _}
    end
  end

  describe "Grabber.run_grab/3" do
    test "removes the just-added torrent when its row was deleted mid-grab" do
      movie = media_item_fixture(%{type: "movie", title: "The Velvet Quarry"})

      {:ok, download} =
        History.create_download(%{
          indexer: "Orphan Indexer",
          title: "The.Velvet.Quarry.1080p",
          media_item_id: movie.id
        })

      Repo.delete!(download)

      capture_log(fn ->
        assert :error = Grabber.run_grab(download, result(), media_item_id: movie.id)
      end)

      assert_received {:removed, @client_id, opts}
      assert opts[:delete_files] == true
    end
  end

  describe "ClientSelection.undo_add/3" do
    setup do
      {:ok, config} = Queue.ClientSelection.find_client_config(@client)
      %{config: config}
    end

    # Another grab saved a row for the same torrent after this grab took its
    # snapshot: the torrent is that row's now, so the rollback leaves it.
    test "keeps a torrent a row claimed after the snapshot", %{config: config} do
      other = media_item_fixture(%{type: "movie", title: "The Tin Observatory"})

      {:ok, _row} =
        History.create_download(%{
          title: "The.Tin.Observatory.1080p",
          media_item_id: other.id,
          download_client: @client,
          download_client_id: @client_id
        })

      assert :ok = Queue.ClientSelection.undo_add(config, @client_id, false)
      refute_received {:removed, _, _}
    end

    test "returns :ok when the client's removal exits", %{config: config} do
      :persistent_term.put({RecordingAdapter, :on_remove}, fn -> exit(:noproc) end)

      log =
        capture_log(fn ->
          assert :ok = Queue.ClientSelection.undo_add(config, @client_id, false)
        end)

      assert log =~ "Could not remove an untracked torrent"
    end
  end

  defp result do
    %SearchResult{
      title: "The.Orphan.Release.1080p.WEB-DL",
      indexer: "Orphan Indexer",
      download_url: "magnet:?xt=urn:btih:#{String.duplicate("a", 40)}",
      size: 1_000,
      seeders: 10,
      leechers: 1,
      download_protocol: :torrent
    }
  end

  defp setup_runtime_config do
    config = %Mydia.Config.Schema{
      server: %Mydia.Config.Schema.Server{},
      database: %Mydia.Config.Schema.Database{},
      auth: %Mydia.Config.Schema.Auth{},
      media: %Mydia.Config.Schema.Media{},
      downloads: %Mydia.Config.Schema.Downloads{},
      logging: %Mydia.Config.Schema.Logging{},
      oban: %Mydia.Config.Schema.Oban{},
      download_clients: []
    }

    previous = Application.get_env(:mydia, :runtime_config)
    Application.put_env(:mydia, :runtime_config, config)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:mydia, :runtime_config)
        value -> Application.put_env(:mydia, :runtime_config, value)
      end
    end)
  end
end
