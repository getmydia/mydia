defmodule Mydia.Downloads.Queue.FilePreviewTest do
  @moduledoc """
  A preview lists a torrent's files and Mydia's automatic picks without adding
  it; a confirmed grab then adds it with the operator's choice, reusing the
  preview's input and listing. rqbit runs behind Bypass as a runtime client.

  `async: false`: the runtime config and the adapter registry are global.
  """
  use Mydia.DataCase, async: false

  import ExUnit.CaptureLog
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Downloads
  alias Mydia.Downloads.{Download, Grabber, History, Queue}
  alias Mydia.Downloads.Client.{Error, Registry}
  alias Mydia.Downloads.Queue.FilePreview
  alias Mydia.Downloads.Structs.TorrentFile
  alias Mydia.Indexers.SearchResult
  alias Mydia.Indexers.Structs.SearchResultMetadata

  @hash "fedcba9876543210fedcba9876543210fedcba98"
  @pack "The.Lantern.Keepers.S02"
  # Index of the subtitle that follows the ten episodes in the listing.
  @subtitle 10

  defmodule PlainAdapter do
    @behaviour Mydia.Downloads.Client

    @impl true
    def add_torrent(_config, _torrent, _opts), do: {:ok, "plain-id"}
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

      # The add first asks whether rqbit already holds the hash; it does not.
      Bypass.stub(bypass, "GET", "/torrents/:id", &Plug.Conn.resp(&1, 404, ""))

      show = media_item_fixture(%{type: "tv_show", title: "The Lantern Keepers"})

      eps =
        for n <- 1..10 do
          episode_fixture(%{media_item_id: show.id, season_number: 2, episode_number: n})
        end

      for ep <- Enum.take(eps, 4), do: media_file_fixture(%{episode_id: ep.id})

      %{bypass: bypass, show: show, eps: eps}
    end

    test "previews a magnet without adding it", ctx do
      expect_rqbit(ctx.bypass, listing: :ok)

      assert {:ok, %FilePreview{} = preview} =
               FilePreview.build(pack_result(ctx.eps), media_item_id: ctx.show.id)

      assert_received {:list_only, _}
      refute_received {:add, _}

      files = FilePreview.files(preview)
      assert [%TorrentFile{index: 0, size: 100} | _] = files
      assert length(files) == 11
      assert Enum.at(files, 4).path == "#{@pack}/#{@pack}E05.1080p.mkv"
      assert preview.peers == ["10.0.0.2:6881"]
    end

    test "auto picks match the grab path", ctx do
      expect_rqbit(ctx.bypass, listing: :ok)

      assert {:ok, preview} =
               Downloads.preview_files(pack_result(ctx.eps), media_item_id: ctx.show.id)

      picks = FilePreview.auto_selected(preview)
      # E01..E04 are owned.
      for owned <- 0..3, do: refute(MapSet.member?(picks, owned))
      for wanted <- 4..9, do: assert(MapSet.member?(picks, wanted))

      included = for %TorrentFile{included?: true, index: i} <- FilePreview.files(preview), do: i
      assert MapSet.new(included) == picks
    end

    test "an empty listing is :no_files", ctx do
      expect_rqbit(ctx.bypass, listing: :empty)

      assert {:error, :no_files} =
               FilePreview.build(pack_result(ctx.eps), media_item_id: ctx.show.id)
    end

    test "a failed listing returns the error", ctx do
      expect_rqbit(ctx.bypass, listing: :error)

      assert {:error, %Error{}} =
               FilePreview.build(pack_result(ctx.eps), media_item_id: ctx.show.id)
    end

    test "a duplicate is refused before any fetch", ctx do
      result = pack_result(ctx.eps)

      # A grab still in flight for the same season pack.
      {:ok, _grabbing} =
        History.create_download(%{
          indexer: result.indexer,
          title: result.title,
          download_url: result.download_url,
          media_item_id: ctx.show.id,
          metadata: Queue.build_download_metadata(result)
        })

      capture_log(fn ->
        assert {:error, :duplicate_download} =
                 FilePreview.build(result, media_item_id: ctx.show.id)
      end)

      refute_received {:list_only, _}
    end

    test "confirming adds with the chosen files and fetches nothing again", ctx do
      expect_rqbit(ctx.bypass, listing: :ok)
      result = pack_result(ctx.eps)
      opts = [media_item_id: ctx.show.id, manual: true]

      {:ok, preview} = FilePreview.build(result, opts)
      assert_received {:list_only, _}

      download = grabbing_row(result, ctx.show.id)

      assert :ok =
               Grabber.run_grab(
                 download,
                 result,
                 opts ++ [file_preview: preview, only_files: [1]]
               )

      refute_received {:list_only, _}
      assert_received {:add, add_params}
      refute_received {:add, _}
      assert add_params["only_files"] == "1"
      assert add_params["initial_peers"] == "10.0.0.2:6881"

      reloaded = Repo.get!(Download, download.id)
      assert reloaded.download_client_id == @hash
      assert reloaded.metadata["file_selection"] == %{"source" => "manual"}
      assert reloaded.metadata["selected_files"] == [1]
      assert reloaded.metadata["file_episodes"]["1"] == Enum.at(ctx.eps, 1).id
    end

    test "confirming a choice without a video fails the grab", ctx do
      expect_rqbit(ctx.bypass, listing: :ok)
      result = pack_result(ctx.eps)
      opts = [media_item_id: ctx.show.id, manual: true]

      {:ok, preview} = FilePreview.build(result, opts)
      download = grabbing_row(result, ctx.show.id)
      Phoenix.PubSub.subscribe(Mydia.PubSub, "downloads")

      capture_log(fn ->
        assert :error =
                 Grabber.run_grab(
                   download,
                   result,
                   opts ++ [file_preview: preview, only_files: [@subtitle]]
                 )
      end)

      refute_received {:add, _}
      download_id = download.id
      assert_received {:grab_failed, %{download_id: ^download_id, reason: reason}}
      assert reason =~ "no_importable_file"

      reloaded = Repo.get!(Download, download.id)
      assert is_nil(reloaded.download_client_id)
      assert reloaded.error_message =~ "no_importable_file"
    end

    test "a manual selection that raises fails the grab instead of crashing it", ctx do
      expect_rqbit(ctx.bypass, listing: :ok)
      result = pack_result(ctx.eps)
      opts = [media_item_id: ctx.show.id, manual: true]

      {:ok, preview} = FilePreview.build(result, opts)
      # An id the episode query cannot cast makes WantedFiles.manual/3 raise.
      broken_item = %{preview.context.media_item | id: :not_a_uuid}
      preview = %{preview | context: %{preview.context | media_item: broken_item}}
      download = grabbing_row(result, ctx.show.id)
      Phoenix.PubSub.subscribe(Mydia.PubSub, "downloads")

      capture_log(fn ->
        assert :error =
                 Grabber.run_grab(
                   download,
                   result,
                   opts ++ [file_preview: preview, only_files: [1]]
                 )
      end)

      refute_received {:add, _}
      download_id = download.id
      assert_received {:grab_failed, %{download_id: ^download_id, reason: reason}}
      assert reason =~ "file_selection_failed"
    end

    test "file_choice_available? follows the priority client" do
      assert Downloads.file_choice_available?()
    end
  end

  describe "a client without file selection" do
    setup do
      setup_runtime_config([])
      previous = Registry.lookup(:transmission)
      Registry.register(:transmission, PlainAdapter)

      on_exit(fn ->
        if previous,
          do: Registry.register(:transmission, previous),
          else: Registry.unregister(:transmission)
      end)

      download_client_config_fixture(%{name: "plain-client", type: "transmission"})
      :ok
    end

    test "is unsupported" do
      capture_log(fn ->
        assert {:error, :unsupported} = FilePreview.build(pack_result([]), [])
      end)
    end

    test "file_choice_available? is false" do
      capture_log(fn -> refute Downloads.file_choice_available?() end)
    end
  end

  # -- helpers ------------------------------------------------------------

  defp grabbing_row(result, media_item_id) do
    {:ok, download} =
      History.create_download(%{
        indexer: result.indexer,
        title: result.title,
        download_url: result.download_url,
        media_item_id: media_item_id,
        metadata: Queue.build_download_metadata(result)
      })

    download
  end

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

  defp expect_rqbit(bypass, opts) do
    listing = Keyword.fetch!(opts, :listing)
    test_pid = self()

    Bypass.expect(bypass, "POST", "/torrents", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      if conn.query_params["list_only"] == "true" do
        send(test_pid, {:list_only, conn.query_params})
        listing_response(conn, listing)
      else
        send(test_pid, {:add, conn.query_params})
        json_resp(conn, 200, %{"id" => 0, "details" => %{"id" => 0, "info_hash" => @hash}})
      end
    end)
  end

  defp listing_response(conn, :ok), do: json_resp(conn, 200, listing_body(files()))
  defp listing_response(conn, :empty), do: json_resp(conn, 200, listing_body([]))

  defp listing_response(conn, :error),
    do: json_resp(conn, 500, %{"error_kind" => "internal_error", "human_readable" => "nope"})

  defp files do
    episodes =
      for n <- 1..10 do
        num = n |> Integer.to_string() |> String.pad_leading(2, "0")
        name = "#{@pack}E#{num}.1080p.mkv"
        %{"name" => name, "components" => [@pack, name], "length" => 100}
      end

    subtitle = "#{@pack}E01.en.srt"
    episodes ++ [%{"name" => subtitle, "components" => [@pack, subtitle], "length" => 1}]
  end

  defp listing_body(files) do
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
