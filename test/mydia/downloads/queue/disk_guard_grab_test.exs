defmodule Mydia.Downloads.Queue.DiskGuardGrabTest do
  @moduledoc """
  The grab path refuses a torrent the built-in client's download volume cannot
  hold. rqbit runs behind Bypass as a runtime client flagged `managed`.

  `async: false`: the runtime config and the built-in runtime are global.
  """
  use Mydia.DataCase, async: false

  import ExUnit.CaptureLog

  alias Mydia.Downloads.{BuiltIn, Queue, ReleaseBlacklist}
  alias Mydia.Downloads.BuiltIn.{Config, Runtime, Status}
  alias Mydia.Downloads.Client.Error
  alias Mydia.Indexers.SearchResult

  @hash "0123456789abcdef0123456789abcdef01234567"
  @gb 1_000_000_000

  setup do
    bypass = Bypass.open()
    test_pid = self()

    # The grab first asks whether rqbit already holds the hash; it does not.
    Bypass.stub(bypass, "GET", "/torrents/:id", &Plug.Conn.resp(&1, 404, ""))

    Bypass.stub(bypass, "POST", "/torrents", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      if conn.query_params["list_only"] == "true" do
        body = %{
          "id" => nil,
          "seen_peers" => [],
          "details" => %{
            "info_hash" => @hash,
            "files" => [
              %{"name" => "a.mkv", "components" => ["a.mkv"], "length" => 41_200_000_000}
            ]
          }
        }

        json_resp(conn, 200, body)
      else
        send(test_pid, :add)
        json_resp(conn, 200, %{"id" => 0, "details" => %{"id" => 0, "info_hash" => @hash}})
      end
    end)

    put_runtime_clients([client(bypass.port, true)])
    put_builtin_runtime(5 * @gb)

    start_supervised!({Status, name: Status})
    Status.put(:engine, :running)
    on_exit(&BuiltIn.clear_runtime/0)

    %{bypass: bypass}
  end

  test "refuses a grab that does not fit, adds nothing, blacklists nothing" do
    assert {:error, {:client_error, %Error{type: :insufficient_space} = error}} =
             grab(free(12_800_000_000))

    assert error.message ==
             "Not enough space on the download volume: needs 41.2 GB, 12.8 GB free, 5 GB kept free"

    assert error.details == %{needed: 41_200_000_000, free: 12_800_000_000, reserve: 5 * @gb}
    refute_received :add
    assert Repo.all(ReleaseBlacklist) == []
  end

  test "adds when the grab fits" do
    assert {:ok, _config, @hash, :torrent, _} = grab(free(100 * @gb))
    assert_received :add
  end

  test "a zero reserve disables the guard without measuring" do
    put_builtin_runtime(0)
    assert {:ok, _, @hash, :torrent, _} = grab(&flunk_free/1)
    assert_received :add
  end

  test "a failed measurement warns and adds" do
    log =
      capture_log(fn ->
        assert {:ok, _, @hash, :torrent, _} = grab(fn _ -> {:error, :enoent} end)
      end)

    assert log =~ "enoent"
    assert_received :add
  end

  test "a non-managed client never measures", %{bypass: bypass} do
    put_runtime_clients([client(bypass.port, false)])
    assert {:ok, _, @hash, :torrent, _} = grab(&flunk_free/1)
    assert_received :add
  end

  test "an unlistable torrent falls back to the advertised size", %{bypass: bypass} do
    test_pid = self()

    Bypass.stub(bypass, "POST", "/torrents", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      if conn.query_params["list_only"] == "true" do
        json_resp(conn, 500, %{"error_kind" => "internal_error", "human_readable" => "no"})
      else
        send(test_pid, :add)
        json_resp(conn, 200, %{"id" => 0, "details" => %{"id" => 0, "info_hash" => @hash}})
      end
    end)

    capture_log(fn ->
      assert {:error, {:client_error, %Error{type: :insufficient_space}}} =
               grab(free(10 * @gb), size: 20 * @gb)
    end)
  end

  test "an unlistable torrent with no advertised size skips the check", %{bypass: bypass} do
    test_pid = self()

    Bypass.stub(bypass, "POST", "/torrents", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      if conn.query_params["list_only"] == "true" do
        json_resp(conn, 500, %{"error_kind" => "internal_error", "human_readable" => "no"})
      else
        send(test_pid, :add)
        json_resp(conn, 200, %{"id" => 0, "details" => %{"id" => 0, "info_hash" => @hash}})
      end
    end)

    capture_log(fn ->
      assert {:ok, _, @hash, :torrent, nil} = grab(&flunk_free/1, size: nil)
    end)

    assert_received :add
  end

  # -- helpers ------------------------------------------------------------

  defp grab(free_bytes, extra \\ []) do
    result = %SearchResult{
      title: "Some.Release.1080p",
      indexer: "Velvet Lantern",
      download_url: "magnet:?xt=urn:btih:#{@hash}",
      size: Keyword.get(extra, :size, 1_000),
      seeders: 10,
      leechers: 1,
      download_protocol: :torrent
    }

    Queue.select_and_add_to_client(result, download_type: :torrent, free_bytes: free_bytes)
  end

  defp free(bytes), do: fn _path -> {:ok, bytes} end
  defp flunk_free(_path), do: flunk("free_bytes must not be called")

  defp put_builtin_runtime(reserve) do
    BuiltIn.put_runtime(%Runtime{
      api_port: 1,
      credentials: {"u", "p"},
      config: %Config{download_path: "/data/downloads", min_free_space_bytes: reserve}
    })
  end

  defp json_resp(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  defp client(port, managed?) do
    %{
      name: "guarded-rqbit",
      type: :rqbit,
      enabled: true,
      host: "localhost",
      port: port,
      use_ssl: false,
      priority: 1,
      connection_settings: %{timeout: 500, managed: managed?}
    }
  end

  defp put_runtime_clients(download_clients) do
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
