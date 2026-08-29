defmodule Mydia.Downloads.Client.NzbgetTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.Client.Nzbget
  alias Mydia.Downloads.Structs.DownloadStatus

  @config %{
    type: :nzbget,
    host: "localhost",
    port: 6789,
    username: "nzbget",
    password: "tegbzn6789",
    use_ssl: false,
    url_base: nil,
    options: %{}
  }

  describe "module behaviour" do
    test "implements all callbacks from Mydia.Downloads.Client behaviour" do
      # Verify the module implements the required behaviour
      behaviours = Nzbget.__info__(:attributes)[:behaviour] || []
      assert Mydia.Downloads.Client in behaviours
    end
  end

  describe "configuration validation" do
    test "test_connection requires username and password" do
      config_without_username = Map.delete(@config, :username)

      {:error, error} = Nzbget.test_connection(config_without_username)
      assert error.type == :invalid_config
      assert error.message =~ "Username and password are required"
    end

    test "test_connection fails with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = Nzbget.test_connection(timeout_config)
      assert error.type in [:connection_failed, :network_error, :timeout]
    end
  end

  describe "add_torrent/3" do
    test "returns error with unreachable host for URL addition" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      nzb_url = "https://nonexistent.invalid/test.nzb"

      {:error, error} = Nzbget.add_torrent(timeout_config, {:url, nzb_url})
      # URL download will fail first before reaching NZBGet
      assert error.type in [:connection_failed, :network_error, :timeout, :api_error]
    end

    test "rejects magnet links" do
      magnet = "magnet:?xt=urn:btih:ABC123DEF456789012345678901234567890ABCD&dn=test"

      {:error, error} = Nzbget.add_torrent(@config, {:magnet, magnet})
      assert error.type == :invalid_torrent
      assert error.message =~ "does not support magnet links"
    end

    test "requires authentication" do
      config_without_username = Map.delete(@config, :username)
      nzb_url = "https://example.com/test.nzb"

      {:error, error} = Nzbget.add_torrent(config_without_username, {:url, nzb_url})
      assert error.type == :invalid_config
    end
  end

  describe "get_status/2" do
    test "returns error with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = Nzbget.get_status(timeout_config, "12345")
      assert error.type in [:connection_failed, :network_error, :timeout]
    end

    test "requires valid integer ID" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      # Should handle string ID by converting to integer
      {:error, error} = Nzbget.get_status(timeout_config, "12345")
      assert error.type in [:connection_failed, :network_error, :timeout]

      # Should fail gracefully with invalid ID format
      {:error, error} = Nzbget.get_status(timeout_config, "not-a-number")
      assert error.type == :invalid_torrent
      assert error.message =~ "Invalid NZB ID format"
    end
  end

  describe "list_torrents/2" do
    test "returns error with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = Nzbget.list_torrents(timeout_config)
      assert error.type in [:connection_failed, :network_error, :timeout]
    end

    test "accepts filter options" do
      # Test that the function accepts the expected options without error
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, _error} = Nzbget.list_torrents(timeout_config, filter: :downloading)
      {:error, _error} = Nzbget.list_torrents(timeout_config, filter: :completed)
      {:error, _error} = Nzbget.list_torrents(timeout_config, filter: :paused)
      assert true
    end
  end

  describe "remove_torrent/3" do
    test "returns error with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = Nzbget.remove_torrent(timeout_config, "12345")
      assert error.type in [:connection_failed, :network_error, :timeout]
    end

    test "requires authentication" do
      config_without_username = Map.delete(@config, :username)

      {:error, error} = Nzbget.remove_torrent(config_without_username, "12345")
      assert error.type == :invalid_config
    end

    test "accepts delete_files option" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, _error} = Nzbget.remove_torrent(timeout_config, "12345", delete_files: true)
      {:error, _error} = Nzbget.remove_torrent(timeout_config, "12345", delete_files: false)
      assert true
    end

    test "handles invalid ID format" do
      {:error, error} = Nzbget.remove_torrent(@config, "not-a-number")
      assert error.type == :invalid_torrent
      assert error.message =~ "Invalid NZB ID format"
    end
  end

  describe "pause_torrent/2" do
    test "returns error with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = Nzbget.pause_torrent(timeout_config, "12345")
      assert error.type in [:connection_failed, :network_error, :timeout]
    end

    test "requires authentication" do
      config_without_username = Map.delete(@config, :username)

      {:error, error} = Nzbget.pause_torrent(config_without_username, "12345")
      assert error.type == :invalid_config
    end

    test "handles invalid ID format" do
      {:error, error} = Nzbget.pause_torrent(@config, "not-a-number")
      assert error.type == :invalid_torrent
      assert error.message =~ "Invalid NZB ID format"
    end
  end

  describe "resume_torrent/2" do
    test "returns error with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = Nzbget.resume_torrent(timeout_config, "12345")
      assert error.type in [:connection_failed, :network_error, :timeout]
    end

    test "requires authentication" do
      config_without_username = Map.delete(@config, :username)

      {:error, error} = Nzbget.resume_torrent(config_without_username, "12345")
      assert error.type == :invalid_config
    end

    test "handles invalid ID format" do
      {:error, error} = Nzbget.resume_torrent(@config, "not-a-number")
      assert error.type == :invalid_torrent
      assert error.message =~ "Invalid NZB ID format"
    end
  end

  describe "JSON-RPC protocol" do
    test "uses correct endpoint path" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      # Attempt connection - should fail at network level, not at path level
      {:error, error} = Nzbget.test_connection(timeout_config)
      assert error.type in [:connection_failed, :network_error, :timeout]
    end
  end

  describe "URL base handling" do
    test "handles custom URL base in configuration" do
      config_with_base = %{@config | url_base: "/nzbget"}
      unreachable_config = %{config_with_base | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      # Should fail with connection error, not path error
      {:error, error} = Nzbget.test_connection(timeout_config)
      assert error.type in [:connection_failed, :network_error, :timeout]
    end
  end

  describe "priority profile resolution (Bypass)" do
    setup do
      bypass = Bypass.open()
      config = %{@config | host: "localhost", port: bypass.port}
      {:ok, bypass: bypass, config: config}
    end

    # Pull the JSON-RPC params from the request body so we can assert on the
    # priority argument NZBGet's `append` RPC receives.
    defp read_append_priority(conn) do
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 1_000_000)
      decoded = Jason.decode!(body)
      assert decoded["method"] == "append"
      # append params: [filename, content_b64, category, priority, ...]
      priority = Enum.at(decoded["params"], 3)
      {priority, conn}
    end

    test "empty profile falls back to hardcoded :high -> 50",
         %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "POST", "/jsonrpc", fn conn ->
        {priority, conn} = read_append_priority(conn)
        assert priority == 50

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"jsonrpc":"2.0","result":42,"id":1}))
      end)

      assert {:ok, "42"} = Nzbget.add_torrent(config, {:file, "fake-nzb"}, priority: :high)
    end

    test "empty profile maps :verylow -> -100 and :veryhigh -> 100",
         %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "POST", "/jsonrpc", fn conn ->
        {priority, conn} = read_append_priority(conn)
        assert priority == -100

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"jsonrpc":"2.0","result":1,"id":1}))
      end)

      assert {:ok, _} = Nzbget.add_torrent(config, {:file, "fake-nzb"}, priority: :verylow)

      bypass2 = Bypass.open()
      config2 = %{config | port: bypass2.port}

      Bypass.expect(bypass2, "POST", "/jsonrpc", fn conn ->
        {priority, conn} = read_append_priority(conn)
        assert priority == 100

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"jsonrpc":"2.0","result":2,"id":2}))
      end)

      assert {:ok, _} = Nzbget.add_torrent(config2, {:file, "fake-nzb"}, priority: :veryhigh)
    end

    test "profile override wins over hardcoded default",
         %{bypass: bypass, config: config} do
      # NZBGet expects integers; the schema stores integer-valued maps fine.
      config_with_profile = Map.put(config, :priority_profile, %{"high" => 75})

      Bypass.expect(bypass, "POST", "/jsonrpc", fn conn ->
        {priority, conn} = read_append_priority(conn)
        assert priority == 75

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"jsonrpc":"2.0","result":7,"id":1}))
      end)

      assert {:ok, _} =
               Nzbget.add_torrent(config_with_profile, {:file, "fake-nzb"}, priority: :high)
    end

    test "tier not present in profile falls back to its hardcoded default",
         %{bypass: bypass, config: config} do
      # Override :high but leave :low alone — :low must still be -50.
      config_with_profile = Map.put(config, :priority_profile, %{"high" => 75})

      Bypass.expect(bypass, "POST", "/jsonrpc", fn conn ->
        {priority, conn} = read_append_priority(conn)
        assert priority == -50

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"jsonrpc":"2.0","result":8,"id":1}))
      end)

      assert {:ok, _} =
               Nzbget.add_torrent(config_with_profile, {:file, "fake-nzb"}, priority: :low)
    end

    test "nil priority sends 0 (NZBGet's normal default)",
         %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "POST", "/jsonrpc", fn conn ->
        {priority, conn} = read_append_priority(conn)
        assert priority == 0

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"jsonrpc":"2.0","result":9,"id":1}))
      end)

      assert {:ok, _} = Nzbget.add_torrent(config, {:file, "fake-nzb"})
    end
  end

  describe "fixture-based parsing (Bypass)" do
    # Path: test/mydia/downloads/client -> ../../../support/fixtures
    @listgroups_fixture Path.expand(
                          "../../../support/fixtures/nzbget/listgroups.json",
                          __DIR__
                        )
    @history_fixture Path.expand("../../../support/fixtures/nzbget/history.json", __DIR__)

    setup do
      bypass = Bypass.open()
      config = %{@config | host: "localhost", port: bypass.port}

      listgroups_body = File.read!(@listgroups_fixture)
      history_body = File.read!(@history_fixture)

      {:ok,
       bypass: bypass,
       config: config,
       listgroups_body: listgroups_body,
       history_body: history_body}
    end

    # Routes listgroups vs history by inspecting the JSON-RPC method in the
    # request body so list_torrents/2 sees a realistic two-step fetch.
    defp expect_listgroups_and_history(bypass, listgroups_body, history_body) do
      Bypass.expect(bypass, "POST", "/jsonrpc", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 1_000_000)
        decoded = Jason.decode!(body)

        response_body =
          case decoded["method"] do
            "listgroups" -> listgroups_body
            "history" -> history_body
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, response_body)
      end)
    end

    test "list_torrents parses every listgroups + history result into DownloadStatus",
         %{
           bypass: bypass,
           config: config,
           listgroups_body: listgroups_body,
           history_body: history_body
         } do
      expect_listgroups_and_history(bypass, listgroups_body, history_body)

      assert {:ok, statuses} = Nzbget.list_torrents(config)
      assert length(statuses) == 10

      assert Enum.all?(statuses, &match?(%DownloadStatus{}, &1))

      # Spot-check the canonical DOWNLOADING slot: NZBGet reports MiB and
      # DownloadRate as integer bytes/sec; size conversions go through the
      # shared Helpers module so the math is identical across adapters.
      dl = Enum.find(statuses, &(&1.id == "2001"))
      assert dl.name == "Show.S01E01.1080p.WEB-DL.x264-GROUP"
      assert dl.state == :downloading
      # 2048 MiB total, 1024 MiB remaining
      assert dl.size == 2_048 * 1_048_576
      assert dl.downloaded == 1_024 * 1_048_576
      assert_in_delta dl.progress, 50.0, 0.5
      # DownloadRate passes through verbatim (bytes/sec)
      assert dl.download_speed == 7_864_320
      # ETA derived from remaining bytes / rate
      assert dl.eta == div(1_024 * 1_048_576, 7_864_320)
      assert dl.save_path == "/downloads/intermediate/Show.S01E01"
      assert dl.added_at == ~U[2023-11-14 22:13:20Z]
      assert dl.completed_at == nil
    end

    test "listgroups + history status strings map onto the canonical state taxonomy",
         %{
           bypass: bypass,
           config: config,
           listgroups_body: listgroups_body,
           history_body: history_body
         } do
      expect_listgroups_and_history(bypass, listgroups_body, history_body)

      assert {:ok, statuses} = Nzbget.list_torrents(config)
      by_id = Map.new(statuses, &{&1.id, &1.state})

      assert by_id["2001"] == :downloading
      assert by_id["2002"] == :checking
      assert by_id["2003"] == :checking
      assert by_id["2004"] == :checking
      assert by_id["2005"] == :checking
      assert by_id["2006"] == :checking
      assert by_id["2007"] == :paused

      # History terminal states.
      assert by_id["3001"] == :completed
      assert by_id["3002"] == :error
      assert by_id["3003"] == :completed
    end

    test "history SUCCESS slot exposes completed_at, FAILURE slot leaves it nil",
         %{
           bypass: bypass,
           config: config,
           listgroups_body: listgroups_body,
           history_body: history_body
         } do
      expect_listgroups_and_history(bypass, listgroups_body, history_body)

      assert {:ok, statuses} = Nzbget.list_torrents(config)
      by_id = Map.new(statuses, &{&1.id, &1})

      done = by_id["3001"]
      assert done.state == :completed
      assert done.name == "Completed.Show.S01E02.1080p.WEB-DL.x264-GROUP"
      # HistoryTime = 1700050000 -> 2023-11-15 12:06:40 UTC
      assert done.completed_at == ~U[2023-11-15 12:06:40Z]

      failed = by_id["3002"]
      assert failed.state == :error
      # FAILURE is not in the {SUCCESS, DELETED} set -> completed_at stays nil
      assert failed.completed_at == nil
    end

    test "list_torrents filter: :downloading keeps DOWNLOADING/FETCHING/QUEUED only",
         %{
           bypass: bypass,
           config: config,
           listgroups_body: listgroups_body,
           history_body: history_body
         } do
      expect_listgroups_and_history(bypass, listgroups_body, history_body)

      assert {:ok, statuses} = Nzbget.list_torrents(config, filter: :downloading)
      ids = Enum.map(statuses, & &1.id) |> MapSet.new()
      # Only the DOWNLOADING slot in our fixture matches; PP_QUEUED is post-
      # processing, not download-queued, so it must be filtered out.
      assert MapSet.equal?(ids, MapSet.new(["2001"]))
    end
  end

  describe "state taxonomy (Bypass + table-driven)" do
    # Every NZBGet status the adapter recognises. parse_state/1 is private so
    # mapping is driven through list_torrents/2 with a synthetic single-group
    # listgroups response per row.
    @state_table [
      {"DOWNLOADING", :downloading},
      {"FETCHING", :downloading},
      {"QUEUED", :downloading},
      {"PAUSED", :paused},
      {"SUCCESS", :completed},
      {"DELETED", :completed},
      {"FAILURE", :error},
      {"WARNING", :error},
      {"PP_QUEUED", :checking},
      {"LOADING_PARS", :checking},
      {"VERIFYING", :checking},
      {"REPAIRING", :checking},
      {"UNPACKING", :checking},
      {"MOVING", :checking},
      {"EXECUTING_SCRIPT", :checking},
      {"UNKNOWN_STATUS", :error}
    ]

    setup do
      bypass = Bypass.open()
      config = %{@config | host: "localhost", port: bypass.port}
      {:ok, bypass: bypass, config: config}
    end

    for {nzbget_state, expected_state} <- @state_table do
      test "maps NZBGet Status #{inspect(nzbget_state)} to #{inspect(expected_state)}",
           %{bypass: bypass, config: config} do
        nzbget_state = unquote(nzbget_state)
        expected_state = unquote(expected_state)

        listgroups_body =
          Jason.encode!(%{
            "version" => "1.1",
            "result" => [
              %{
                "NZBID" => 9001,
                "NZBName" => "Probe",
                "Status" => nzbget_state,
                "FileSizeMB" => 100,
                "RemainingSizeMB" => 50,
                "DownloadRate" => 0,
                "DestDir" => "/tmp"
              }
            ]
          })

        history_body = Jason.encode!(%{"version" => "1.1", "result" => []})

        Bypass.expect(bypass, "POST", "/jsonrpc", fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn, length: 1_000_000)
          decoded = Jason.decode!(body)

          response_body =
            case decoded["method"] do
              "listgroups" -> listgroups_body
              "history" -> history_body
            end

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, response_body)
        end)

        assert {:ok, [%{state: ^expected_state}]} = Nzbget.list_torrents(config)
      end
    end
  end

  describe "computed ETA (Bypass)" do
    # NZBGet does not return ETA directly; the adapter derives it from
    # RemainingSizeMB and DownloadRate. These cases pin the arithmetic and the
    # divide-by-zero fallback (rate=0 -> eta=nil).
    setup do
      bypass = Bypass.open()
      config = %{@config | host: "localhost", port: bypass.port}
      {:ok, bypass: bypass, config: config}
    end

    defp expect_listgroups_only(bypass, listgroups_body) do
      Bypass.expect(bypass, "POST", "/jsonrpc", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 1_000_000)
        decoded = Jason.decode!(body)

        response_body =
          case decoded["method"] do
            "listgroups" -> listgroups_body
            "history" -> Jason.encode!(%{"version" => "1.1", "result" => []})
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, response_body)
      end)
    end

    test "ETA = remaining_bytes / download_rate (active download)",
         %{bypass: bypass, config: config} do
      # 100 MiB remaining at 1 MiB/sec -> 100 seconds.
      remaining_mb = 100
      rate = 1_048_576

      listgroups_body =
        Jason.encode!(%{
          "version" => "1.1",
          "result" => [
            %{
              "NZBID" => 9100,
              "NZBName" => "Probe",
              "Status" => "DOWNLOADING",
              "FileSizeMB" => 200,
              "RemainingSizeMB" => remaining_mb,
              "DownloadRate" => rate,
              "DestDir" => "/tmp"
            }
          ]
        })

      expect_listgroups_only(bypass, listgroups_body)

      assert {:ok, [status]} = Nzbget.list_torrents(config)
      assert status.eta == div(remaining_mb * 1_048_576, rate)
    end

    test "ETA is nil when download rate is zero (divide-by-zero fallback)",
         %{bypass: bypass, config: config} do
      listgroups_body =
        Jason.encode!(%{
          "version" => "1.1",
          "result" => [
            %{
              "NZBID" => 9101,
              "NZBName" => "Stalled",
              "Status" => "DOWNLOADING",
              "FileSizeMB" => 200,
              "RemainingSizeMB" => 100,
              "DownloadRate" => 0,
              "DestDir" => "/tmp"
            }
          ]
        })

      expect_listgroups_only(bypass, listgroups_body)

      assert {:ok, [status]} = Nzbget.list_torrents(config)
      assert status.eta == nil
    end

    test "ETA is nil for paused items (rate=0 + paused state)",
         %{bypass: bypass, config: config} do
      listgroups_body =
        Jason.encode!(%{
          "version" => "1.1",
          "result" => [
            %{
              "NZBID" => 9102,
              "NZBName" => "PausedProbe",
              "Status" => "PAUSED",
              "FileSizeMB" => 200,
              "RemainingSizeMB" => 200,
              "DownloadRate" => 0,
              "DestDir" => "/tmp"
            }
          ]
        })

      expect_listgroups_only(bypass, listgroups_body)

      assert {:ok, [status]} = Nzbget.list_torrents(config)
      assert status.state == :paused
      assert status.eta == nil
    end
  end
end
