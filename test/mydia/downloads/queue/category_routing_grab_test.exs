defmodule Mydia.Downloads.Queue.CategoryRoutingGrabTest do
  @moduledoc """
  A grab sends the client the category configured for the item's content type,
  and logs what it chose so an "added without a category" report (#1442) can
  be read from the logs.

  `async: false`: the adapter registry is global.
  """
  use Mydia.DataCase, async: false

  import ExUnit.CaptureLog
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Downloads.Queue
  alias Mydia.Downloads.Client.{Error, Registry}
  alias Mydia.Indexers.SearchResult

  defmodule RecordingAdapter do
    @behaviour Mydia.Downloads.Client

    @impl true
    def add_torrent(_config, _torrent, opts) do
      send(:persistent_term.get({__MODULE__, :pid}), {:add, opts})
      {:ok, "recorded-id"}
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

  setup do
    # The decision is logged at info; test config runs at warning.
    original_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: original_level) end)

    setup_runtime_config([])
    :persistent_term.put({RecordingAdapter, :pid}, self())
    previous = Registry.lookup(:transmission)
    Registry.register(:transmission, RecordingAdapter)

    on_exit(fn ->
      :persistent_term.erase({RecordingAdapter, :pid})

      if previous,
        do: Registry.register(:transmission, previous),
        else: Registry.unregister(:transmission)
    end)

    :ok
  end

  test "sends and logs the content type's category" do
    client =
      download_client_config_fixture(%{
        type: "transmission",
        categories: %{"movie" => "films", "tv" => "series"}
      })

    movie = media_item_fixture(%{type: "movie"})

    log =
      capture_log(fn ->
        assert {:ok, _config, "recorded-id", _type, _selection} =
                 Queue.select_and_add_to_client(result(), media_item_id: movie.id)
      end)

    assert_received {:add, opts}
    assert opts[:category] == "films"
    assert log =~ ~s(client="#{client.name}")
    assert log =~ ~s(content_type="movie")
    assert log =~ ~s(category="films")
  end

  test "logs a missing category as none" do
    download_client_config_fixture(%{type: "transmission"})
    movie = media_item_fixture(%{type: "movie"})

    log =
      capture_log(fn ->
        assert {:ok, _config, "recorded-id", _type, _selection} =
                 Queue.select_and_add_to_client(result(), media_item_id: movie.id)
      end)

    assert_received {:add, opts}
    refute Keyword.has_key?(opts, :category)
    assert log =~ "category=none"
  end

  defp result do
    %SearchResult{
      title: "Quiet.Harbour.2024.1080p.WEB-DL",
      indexer: "Velvet Lantern",
      download_url:
        "magnet:?xt=urn:btih:#{:crypto.strong_rand_bytes(20) |> Base.encode16(case: :lower)}",
      size: 1_000,
      seeders: 10,
      leechers: 1,
      download_protocol: :torrent
    }
  end

  # No runtime (env-configured) clients, so the DB fixture is the only one.
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
