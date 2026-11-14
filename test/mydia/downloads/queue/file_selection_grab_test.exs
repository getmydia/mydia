defmodule Mydia.Downloads.Queue.FileSelectionGrabTest do
  @moduledoc """
  The grab path lists a torrent's files, keeps the wanted ones and records the
  selection on the download. rqbit runs behind Bypass as a runtime client.

  `async: false`: the runtime config and the adapter registry are global.
  """
  use Mydia.DataCase, async: false

  import ExUnit.CaptureLog
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Downloads.{Download, FileSelection, Grabber, History, Queue}
  alias Mydia.Downloads.Client.{Error, Registry}
  alias Mydia.Indexers.SearchResult
  alias Mydia.Indexers.Structs.SearchResultMetadata

  @hash "0123456789abcdef0123456789abcdef01234567"
  @pack "The.Lantern.Keepers.S02"

  defmodule PlainAdapter do
    @behaviour Mydia.Downloads.Client

    @impl true
    def add_torrent(_config, _torrent, opts) do
      send(:persistent_term.get({__MODULE__, :pid}), {:plain_add, opts})
      {:ok, "plain-id"}
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
    def remove_torrent(_config, _client_id, _opts), do: :ok
    @impl true
    def pause_torrent(_config, _client_id), do: :ok
    @impl true
    def resume_torrent(_config, _client_id), do: :ok
  end

  describe "with rqbit" do
    setup do
      bypass = Bypass.open()
      setup_runtime_config([rqbit_client(bypass.port)])

      show = media_item_fixture(%{type: "tv_show", title: "The Lantern Keepers"})

      eps =
        for n <- 1..10 do
          episode_fixture(%{media_item_id: show.id, season_number: 2, episode_number: n})
        end

      for ep <- Enum.take(eps, 4), do: media_file_fixture(%{episode_id: ep.id})

      %{bypass: bypass, show: show, eps: eps}
    end

    test "lists, then adds with only_files and initial_peers, and records the selection", ctx do
      expect_rqbit(ctx.bypass, listing: :ok)

      assert {:ok, download} =
               Queue.initiate_download(pack_result(ctx.eps), media_item_id: ctx.show.id)

      assert_received {:list_only, _}
      assert_received {:add, add_params}
      assert add_params["only_files"] == "4,5,6,7,8,9"
      assert add_params["initial_peers"] == "10.0.0.2:6881"

      e05 = Enum.at(ctx.eps, 4)
      assert download.metadata["selected_files"] == [4, 5, 6, 7, 8, 9]
      assert download.metadata["file_episodes"]["4"] == e05.id

      reloaded = Repo.get!(Download, download.id)
      assert reloaded.metadata["selected_files"] == [4, 5, 6, 7, 8, 9]
      assert reloaded.metadata["season_pack"] == true
      assert reloaded.metadata["indexer"] == "Velvet Lantern"
    end

    test "Grabber.run_grab records the selection on the existing row", ctx do
      expect_rqbit(ctx.bypass, listing: :ok)
      result = pack_result(ctx.eps)

      {:ok, download} =
        History.create_download(%{
          indexer: result.indexer,
          title: result.title,
          download_url: result.download_url,
          media_item_id: ctx.show.id,
          metadata: Queue.build_download_metadata(result)
        })

      assert :ok = Grabber.run_grab(download, result, media_item_id: ctx.show.id)

      reloaded = Repo.get!(Download, download.id)
      assert reloaded.download_client_id == @hash
      assert reloaded.metadata["selected_files"] == [4, 5, 6, 7, 8, 9]
      assert reloaded.metadata["file_episodes"]["5"] == Enum.at(ctx.eps, 5).id
      assert reloaded.metadata["season_pack"] == true
      assert reloaded.metadata["indexer"] == "Velvet Lantern"
    end

    test "falls back to adding every file when list_only errors", ctx do
      expect_rqbit(ctx.bypass, listing: :error)

      log =
        capture_log(fn ->
          assert {:ok, _config, @hash, :torrent, nil} =
                   Queue.select_and_add_to_client(pack_result(ctx.eps),
                     media_item_id: ctx.show.id,
                     download_type: :torrent
                   )
        end)

      assert_received {:list_only, _}
      assert_received {:add, add_params}
      refute Map.has_key?(add_params, "only_files")
      refute Map.has_key?(add_params, "initial_peers")
      assert log =~ "adding every file"
    end

    test "falls back when list_only times out", ctx do
      expect_rqbit(ctx.bypass, listing: :slow)

      log =
        capture_log(fn ->
          assert {:ok, _config, @hash, :torrent, nil} =
                   Queue.select_and_add_to_client(pack_result(ctx.eps),
                     media_item_id: ctx.show.id,
                     download_type: :torrent
                   )
        end)

      assert_received {:add, add_params}
      refute Map.has_key?(add_params, "only_files")
      assert log =~ "adding every file"
      assert_receive :slow_listing_done, 2_000
    end

    test "falls back when FileSelection raises", ctx do
      expect_rqbit(ctx.bypass, listing: :ok)

      # An integer is not a valid binary id, so the context lookup raises.
      log =
        capture_log(fn ->
          assert {:ok, _config, @hash, :torrent, nil} =
                   Queue.select_and_add_to_client(pack_result(ctx.eps),
                     episode_id: 123,
                     download_type: :torrent
                   )
        end)

      assert_received {:add, add_params}
      refute Map.has_key?(add_params, "only_files")
      # Listing succeeded, so its peers still seed the add.
      assert add_params["initial_peers"] == "10.0.0.2:6881"
      assert log =~ "File selection failed; adding every file"
    end

    test "a keep-everything selection is returned and recorded without only_files", ctx do
      expect_rqbit(ctx.bypass, listing: :ok)

      assert {:ok, _config, @hash, :torrent, %FileSelection{only_files: nil} = sel} =
               Queue.select_and_add_to_client(pack_result(ctx.eps),
                 episode_id: Enum.at(ctx.eps, 0).id,
                 download_type: :torrent
               )

      assert map_size(sel.file_episodes) == 10
      assert_received {:add, add_params}
      refute Map.has_key?(add_params, "only_files")
    end
  end

  describe "an adapter without list_torrent_files" do
    setup do
      setup_runtime_config([])
      :persistent_term.put({PlainAdapter, :pid}, self())
      previous = Registry.lookup(:transmission)
      Registry.register(:transmission, PlainAdapter)

      on_exit(fn ->
        :persistent_term.erase({PlainAdapter, :pid})
        if previous, do: Registry.register(:transmission, previous)
      end)

      download_client_config_fixture(%{name: "plain-client", type: "transmission"})
      :ok
    end

    test "adds as before and returns nil selection" do
      log =
        capture_log(fn ->
          assert {:ok, _config, "plain-id", :torrent, nil} =
                   Queue.select_and_add_to_client(pack_result([]), download_type: :torrent)
        end)

      assert_received {:plain_add, opts}
      refute Keyword.has_key?(opts, :only_files)
      refute Keyword.has_key?(opts, :initial_peers)
      refute log =~ "adding every file"
    end
  end

  # -- helpers ------------------------------------------------------------

  defp pack_result(eps) do
    %SearchResult{
      title: "#{@pack}.1080p.WEB-DL",
      indexer: "Velvet Lantern",
      download_url: "magnet:?xt=urn:btih:#{@hash}",
      size: 1_000,
      seeders: 10,
      leechers: 1,
      download_protocol: :torrent,
      metadata: SearchResultMetadata.season_pack(2, 10, eps |> Enum.drop(4) |> Enum.map(& &1.id))
    }
  end

  defp expect_rqbit(bypass, listing: listing) do
    test_pid = self()

    Bypass.expect(bypass, "POST", "/torrents", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      if conn.query_params["list_only"] == "true" do
        send(test_pid, {:list_only, conn.query_params})
        conn |> Plug.Conn.put_private(:test_pid, test_pid) |> listing_response(listing)
      else
        send(test_pid, {:add, conn.query_params})
        json_resp(conn, 200, %{"id" => 0, "details" => %{"id" => 0, "info_hash" => @hash}})
      end
    end)
  end

  defp listing_response(conn, :ok), do: json_resp(conn, 200, listing_body())

  defp listing_response(conn, :error),
    do: json_resp(conn, 500, %{"error_kind" => "internal_error", "human_readable" => "nope"})

  # Sleeps past the client's 200ms timeout. The client's hang-up would kill
  # this handler, which Bypass reports as a failure, so it traps exits and the
  # test waits for `:slow_listing_done` before Bypass shuts down.
  defp listing_response(conn, :slow) do
    Process.flag(:trap_exit, true)
    Process.sleep(400)
    conn = json_resp(conn, 200, listing_body())
    send(conn.private[:test_pid], :slow_listing_done)
    conn
  end

  defp listing_body do
    files =
      for n <- 1..10 do
        num = n |> Integer.to_string() |> String.pad_leading(2, "0")
        name = "#{@pack}E#{num}.1080p.mkv"
        %{"name" => name, "components" => [@pack, name], "length" => 100}
      end

    %{
      "id" => nil,
      "seen_peers" => ["10.0.0.2:6881"],
      "details" => %{"info_hash" => @hash, "files" => files}
    }
  end

  defp json_resp(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  defp rqbit_client(port) do
    %{
      name: "lantern-rqbit",
      type: :rqbit,
      enabled: true,
      host: "localhost",
      port: port,
      use_ssl: false,
      priority: 1,
      connection_settings: %{timeout: 200}
    }
  end

  defp setup_runtime_config(download_clients) do
    config = %Mydia.Config.Schema{
      server: %Mydia.Config.Schema.Server{},
      database: %Mydia.Config.Schema.Database{},
      auth: %Mydia.Config.Schema.Auth{},
      media: %Mydia.Config.Schema.Media{},
      downloads: %Mydia.Config.Schema.Downloads{},
      logging: %Mydia.Config.Schema.Logging{},
      oban: %Mydia.Config.Schema.Oban{},
      download_clients: download_clients
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
