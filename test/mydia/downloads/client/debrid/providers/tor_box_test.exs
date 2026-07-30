defmodule Mydia.Downloads.Client.Debrid.Providers.TorBoxTest do
  @moduledoc """
  Bypass-only tests for the TorBox provider — no real-account validation.
  """
  use ExUnit.Case, async: false

  alias Mydia.Downloads.Client.Debrid.Providers.TorBox
  alias Mydia.Downloads.Client.Debrid.ProviderJob
  alias Mydia.Downloads.Client.Error

  setup do
    bypass = Bypass.open()
    base = "http://127.0.0.1:#{bypass.port}"

    prior = Application.get_env(:mydia, :tor_box_base_url)
    Application.put_env(:mydia, :tor_box_base_url, base)
    on_exit(fn -> Application.put_env(:mydia, :tor_box_base_url, prior) end)

    {:ok, bypass: bypass, config: %{api_key: "tb-token", type: :debrid}}
  end

  defp success(data), do: Jason.encode!(%{"success" => true, "data" => data})

  # A real `.torrent` is bencoded with a `pieces` field of raw SHA-1 bytes,
  # so the multipart body must carry arbitrary (invalid-UTF8) bytes through
  # untouched. Using an ASCII-only fixture would not catch a body that gets
  # mangled by an encoding step on the way out.
  defp torrent_fixture do
    "d8:announce13:https://tr/abc4:infod6:lengthi1e4:name7:mayabee6:pieces20:" <>
      <<0xFF, 0xFE, 0x00, 0x01, 0x80, 0x7F, 0xC3, 0x28, 0xA0, 0xA1, 0xF0, 0x9F, 0x92, 0xA9, 0x00,
        0xDE, 0xAD, 0xBE, 0xEF, 0x00>> <> "ee"
  end

  defp torrent(overrides) do
    Map.merge(
      %{
        "id" => 1,
        "download_state" => "downloading",
        "download_finished" => false,
        "download_present" => false,
        "size" => 100,
        "progress" => 0.0,
        "files" => []
      },
      overrides
    )
  end

  describe "validate_credentials/1" do
    test "active plan returns ok", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "GET", "/user/me", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          success(%{"plan" => 1, "premium_expires_at" => "2099-12-31T00:00:00Z"})
        )
      end)

      assert {:ok, _} = TorBox.validate_credentials(config)
    end

    test "BAD_TOKEN returns :authentication_failed", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "GET", "/user/me", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"success" => false, "error" => "BAD_TOKEN"}))
      end)

      assert {:error, %Error{type: :authentication_failed}} =
               TorBox.validate_credentials(config)
    end
  end

  describe "submit_torrent/2" do
    test "magnet returns the integer torrent_id as string", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "POST", "/torrents/createtorrent", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, success(%{"torrent_id" => 42}))
      end)

      assert {:ok, "42"} = TorBox.submit_torrent(config, {:magnet, "magnet:?xt=abc"})
    end

    test "torrent file upload uses Req-compatible multipart body", %{
      bypass: bypass,
      config: config
    } do
      test_pid = self()

      Bypass.expect(bypass, "POST", "/torrents/createtorrent", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 1_000_000)
        send(test_pid, {:upload, Plug.Conn.get_req_header(conn, "content-type"), body})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, success(%{"torrent_id" => 43}))
      end)

      assert {:ok, "43"} = TorBox.submit_torrent(config, {:file, torrent_fixture()})

      assert_received {:upload, [content_type | _], body}
      assert content_type =~ "multipart/form-data"
      assert body =~ ~s(name="file")
      assert body =~ ~s(filename="release.torrent")
      assert body =~ "application/x-bittorrent"
      assert body =~ torrent_fixture()
    end
  end

  describe "get_job/2 ready predicate" do
    test "download_finished && download_present → :ready", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "GET", "/torrents/mylist", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          success(%{
            "id" => 1,
            "download_state" => "completed",
            "download_finished" => true,
            "download_present" => true,
            "size" => 100,
            "progress" => 1.0,
            "files" => []
          })
        )
      end)

      assert {:ok, %ProviderJob{state: :ready}} = TorBox.get_job(config, "1")
    end

    test "download_finished without download_present → :finalizing (no premature ready)",
         %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "GET", "/torrents/mylist", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          success(%{
            "id" => 1,
            "download_state" => "completed",
            "download_finished" => true,
            "download_present" => false,
            "size" => 100,
            "progress" => 1.0,
            "files" => []
          })
        )
      end)

      assert {:ok, %ProviderJob{state: :finalizing}} = TorBox.get_job(config, "1")
    end
  end

  describe "get_job/2 download_state mapping" do
    # TorBox reports a seedless torrent as active-but-stuck, not as a hard
    # failure. Mapping those states to :error made DownloadMonitor delete the
    # queue row and blacklist the release on the very first poll. Keeping them
    # active lets StallDetector observe the lack of progress over the
    # configured grace window and escalate only if it persists.
    for {download_state, expected_state} <- [
          {"stalled (no seeds)", :downloading},
          {"stalledDL", :downloading},
          {"checking", :downloading},
          {"checkingResumeData", :downloading},
          {"missingFiles", :error},
          {"error", :error}
        ] do
      test "#{download_state} maps to #{inspect(expected_state)}", %{
        bypass: bypass,
        config: config
      } do
        Bypass.expect(bypass, "GET", "/torrents/mylist", fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            success(torrent(%{"download_state" => unquote(download_state)}))
          )
        end)

        assert {:ok, %ProviderJob{state: unquote(expected_state)}} = TorBox.get_job(config, "1")
      end
    end
  end

  describe "failure classification" do
    defp failure_payload(download_state) do
      %{
        "id" => 7,
        "name" => "Some.Release.1080p",
        "download_state" => download_state,
        "download_finished" => false,
        "download_present" => false,
        "progress" => 0.0,
        "size" => 100,
        "files" => []
      }
    end

    defp fetch_job(bypass, config, download_state) do
      Bypass.expect(bypass, "GET", "/torrents/mylist", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, success(failure_payload(download_state)))
      end)

      TorBox.get_job(config, "7")
    end

    test "missingFiles classifies as :missing_files", %{bypass: bypass, config: config} do
      assert {:ok, %ProviderJob{} = job} = fetch_job(bypass, config, "missingFiles")

      assert job.state == :error
      assert job.failure_category == :missing_files
      assert job.failure_detail == "missingFiles"
    end

    test "error classifies as :provider_error", %{bypass: bypass, config: config} do
      assert {:ok, %ProviderJob{} = job} = fetch_job(bypass, config, "error")

      assert job.state == :error
      assert job.failure_category == :provider_error
      assert job.failure_detail == "error"
    end

    test "a non-terminal state carries no failure fields", %{bypass: bypass, config: config} do
      assert {:ok, %ProviderJob{} = job} = fetch_job(bypass, config, "downloading")

      assert job.state == :downloading
      assert job.failure_category == nil
      assert job.failure_detail == nil
    end

    test "stalled (no seeds) stays non-terminal and unclassified (PR #221)",
         %{bypass: bypass, config: config} do
      assert {:ok, %ProviderJob{} = job} = fetch_job(bypass, config, "stalled (no seeds)")

      assert job.state == :downloading
      assert job.failure_category == nil
    end
  end

  describe "get_download_urls/2 (descriptors)" do
    test "returns tokenless descriptors with provider/torrent_id/file_id", %{config: config} do
      job = %ProviderJob{
        provider_id: "42",
        state: :ready,
        raw_status: %{
          "id" => 42,
          "files" => [%{"id" => 1}, %{"id" => 2}, %{"id" => 3}]
        }
      }

      assert {:ok, descriptors} = TorBox.get_download_urls(config, job)
      assert length(descriptors) == 3

      assert Enum.all?(descriptors, fn d ->
               d["provider"] == "torbox" and d["torrent_id"] == 42 and is_integer(d["file_id"])
             end)

      # No descriptor should contain a token=value reference.
      refute Enum.any?(descriptors, fn d ->
               Enum.any?(Map.values(d), fn v -> is_binary(v) and v =~ "token=" end)
             end)
    end

    test "descriptors round-trip cleanly through JSON encode/decode", %{config: config} do
      job = %ProviderJob{
        provider_id: "42",
        state: :ready,
        raw_status: %{"id" => 42, "files" => [%{"id" => 1}]}
      }

      assert {:ok, [d]} = TorBox.get_download_urls(config, job)
      assert {:ok, decoded} = Jason.encode(d) |> elem(1) |> Jason.decode()
      assert decoded["provider"] == "torbox"
    end
  end

  describe "materialize_descriptor/2" do
    test "reconstructs a token-bearing URL from descriptor + config", %{config: config} do
      descriptor = %{"torrent_id" => 42, "file_id" => 5}
      assert {:ok, url} = TorBox.materialize_descriptor(config, descriptor)
      assert url =~ "token=tb-token"
      assert url =~ "torrent_id=42"
      assert url =~ "file_id=5"
      assert url =~ "redirect=true"
    end

    test "missing api_key returns :invalid_config" do
      descriptor = %{"torrent_id" => 1, "file_id" => 1}

      assert {:error, %Error{type: :invalid_config}} =
               TorBox.materialize_descriptor(%{api_key: nil}, descriptor)
    end
  end

  describe "list_jobs/2" do
    test "filters to requested ids", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "GET", "/torrents/mylist", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          success([
            %{
              "id" => 1,
              "download_state" => "downloading",
              "download_finished" => false,
              "download_present" => false,
              "size" => 100,
              "progress" => 0.5,
              "files" => []
            },
            %{
              "id" => 2,
              "download_state" => "completed",
              "download_finished" => true,
              "download_present" => true,
              "size" => 50,
              "progress" => 1.0,
              "files" => []
            }
          ])
        )
      end)

      assert {:ok, jobs} = TorBox.list_jobs(config, ["1", "2"])
      assert map_size(jobs) == 2
      assert %ProviderJob{state: :downloading} = jobs["1"]
      assert %ProviderJob{state: :ready} = jobs["2"]
    end
  end

  describe "rate_limit_budget/0" do
    test "returns {300, 60}", do: assert(TorBox.rate_limit_budget() == {300, 60})
  end
end
