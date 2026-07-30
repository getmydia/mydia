defmodule Mydia.Downloads.Client.Debrid.Providers.RealDebridTest do
  @moduledoc """
  Bypass-based tests for the Real-Debrid provider.

  Manual real-account validation steps (`@manual_real_account_steps`):

    1. Set MYDIA_RD_API_KEY in env.
    2. Configure a `:debrid` client with `connection_settings: %{"provider" => "real_debrid"}`.
    3. `Mydia.Downloads.test_connection(client_config)` returns `{:ok, ClientInfo}`.
    4. Submit a known-cached magnet via `Queue.initiate_download/2`. Within
       a minute, `Download.metadata["debrid_urls"]` should contain a single
       `%{"url" => "https://..."}` entry and the Fetcher writes the file
       under the configured staging directory.
    5. Submit an uncached magnet. Status remains `:downloading` for
       extended periods without being flagged stalled (R6 grace default).
    6. Submit a flagged/infringing magnet. Adapter surfaces
       `Error.invalid_torrent/1` and the queue picks the next candidate.
  """
  use ExUnit.Case, async: false

  alias Mydia.Downloads.Client.Debrid.Providers.RealDebrid
  alias Mydia.Downloads.Client.Debrid.ProviderJob
  alias Mydia.Downloads.Client.Error
  alias Mydia.Downloads.Structs.ClientInfo

  setup do
    bypass = Bypass.open()
    base = "http://127.0.0.1:#{bypass.port}"

    prior = Application.get_env(:mydia, :real_debrid_base_url)
    Application.put_env(:mydia, :real_debrid_base_url, base)
    on_exit(fn -> Application.put_env(:mydia, :real_debrid_base_url, prior) end)

    config = %{api_key: "rd-test-token", type: :debrid}
    {:ok, bypass: bypass, config: config}
  end

  describe "validate_credentials/1" do
    test "premium user returns ClientInfo", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "GET", "/user", fn conn ->
        assert ["Bearer rd-test-token"] = Plug.Conn.get_req_header(conn, "authorization")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"type" => "premium", "premium" => 12345}))
      end)

      assert {:ok, %ClientInfo{version: "Real-Debrid (premium)"}} =
               RealDebrid.validate_credentials(config)
    end

    test "free account returns :authentication_failed", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "GET", "/user", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"type" => "free", "premium" => 0}))
      end)

      assert {:error, %Error{type: :authentication_failed}} =
               RealDebrid.validate_credentials(config)
    end

    test "401 + error_code 8 returns :authentication_failed", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "GET", "/user", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(401, Jason.encode!(%{"error_code" => 8, "error" => "bad_token"}))
      end)

      assert {:error, %Error{type: :authentication_failed}} =
               RealDebrid.validate_credentials(config)
    end
  end

  describe "submit_torrent/2" do
    test "magnet via /torrents/addMagnet returns the integer id as string", %{
      bypass: bypass,
      config: config
    } do
      Bypass.expect_once(bypass, "POST", "/torrents/addMagnet", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "magnet="

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, Jason.encode!(%{"id" => "RD123"}))
      end)

      assert {:ok, "RD123"} = RealDebrid.submit_torrent(config, {:magnet, "magnet:?xt=abc"})
    end

    test "file via /torrents/addTorrent uses octet-stream content type", %{
      bypass: bypass,
      config: config
    } do
      Bypass.expect_once(bypass, "PUT", "/torrents/addTorrent", fn conn ->
        assert ["application/x-bittorrent"] = Plug.Conn.get_req_header(conn, "content-type")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, Jason.encode!(%{"id" => "RD124"}))
      end)

      assert {:ok, "RD124"} =
               RealDebrid.submit_torrent(config, {:file, "d8:announce..."})
    end

    test "error_code 33 returns :duplicate_torrent", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "POST", "/torrents/addMagnet", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, Jason.encode!(%{"error_code" => 33, "error" => "duplicate"}))
      end)

      assert {:error, %Error{type: :duplicate_torrent}} =
               RealDebrid.submit_torrent(config, {:magnet, "magnet:?xt=dup"})
    end

    test "error_code 35 returns :invalid_torrent with :infringing reason", %{
      bypass: bypass,
      config: config
    } do
      Bypass.expect(bypass, "POST", "/torrents/addMagnet", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, Jason.encode!(%{"error_code" => 35, "error" => "infringing"}))
      end)

      assert {:error, %Error{type: :invalid_torrent, details: %{reason: :infringing}}} =
               RealDebrid.submit_torrent(config, {:magnet, "magnet:?xt=bad"})
    end

    test "429 returns :api_error with :rate_limited", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "POST", "/torrents/addMagnet", fn conn ->
        Plug.Conn.resp(conn, 429, "")
      end)

      assert {:error, %Error{type: :api_error, details: %{reason: :rate_limited}}} =
               RealDebrid.submit_torrent(config, {:magnet, "magnet:?xt=throttled"})
    end

    test "error_code 7 (unknown_ressource) maps to :invalid_torrent with :rejected_after_acceptance",
         %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "POST", "/torrents/addMagnet", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          404,
          Jason.encode!(%{"error" => "unknown_ressource", "error_code" => 7})
        )
      end)

      assert {:error,
              %Error{
                type: :invalid_torrent,
                details: %{reason: :rejected_after_acceptance, error_code: 7}
              }} =
               RealDebrid.submit_torrent(config, {:magnet, "magnet:?xt=phantom"})
    end
  end

  describe "post_submission_setup/2" do
    test "204 returns :ok", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "POST", "/torrents/selectFiles/RD123", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "files=all"
        Plug.Conn.resp(conn, 204, "")
      end)

      assert :ok = RealDebrid.post_submission_setup(config, "RD123")
    end
  end

  describe "get_job/2" do
    test "parses 'downloading' state", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "GET", "/torrents/info/RD123", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "RD123",
            "status" => "downloading",
            "progress" => 42.5,
            "bytes" => 1_000_000,
            "filename" => "release",
            "links" => []
          })
        )
      end)

      assert {:ok, %ProviderJob{state: :downloading, progress: 42.5, total_bytes: 1_000_000}} =
               RealDebrid.get_job(config, "RD123")
    end

    test "parses 'downloaded' as :ready", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "GET", "/torrents/info/RD123", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "RD123",
            "status" => "downloaded",
            "progress" => 100,
            "bytes" => 1_000_000,
            "links" => ["https://hoster.example/file"]
          })
        )
      end)

      assert {:ok, %ProviderJob{state: :ready, hoster_links: ["https://hoster.example/file"]}} =
               RealDebrid.get_job(config, "RD123")
    end

    test "parses 'error' as :error", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "GET", "/torrents/info/RD123", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"id" => "RD123", "status" => "error", "progress" => 0, "bytes" => 0})
        )
      end)

      assert {:ok, %ProviderJob{state: :error}} = RealDebrid.get_job(config, "RD123")
    end

    test "parses 'magnet_conversion' as :queued", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "GET", "/torrents/info/RD123", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "RD123",
            "status" => "magnet_conversion",
            "progress" => 0,
            "bytes" => 0
          })
        )
      end)

      assert {:ok, %ProviderJob{state: :queued}} = RealDebrid.get_job(config, "RD123")
    end
  end

  describe "failure classification" do
    defp fetch_info(bypass, config, status) do
      Bypass.expect(bypass, "GET", "/torrents/info/RD123", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "RD123",
            "filename" => "Some.Release.1080p",
            "status" => status,
            "progress" => 0.0,
            "bytes" => 1_000_000,
            "files" => [],
            "links" => []
          })
        )
      end)

      RealDebrid.get_job(config, "RD123")
    end

    # One generated test per status, so a single bad mapping doesn't mask
    # the others.
    for {status, category} <- [
          {"dead", :no_peers},
          {"virus", :rejected_content},
          {"magnet_error", :rejected_content},
          {"error", :provider_error}
        ] do
      test "status #{status} classifies as #{inspect(category)}",
           %{bypass: bypass, config: config} do
        assert {:ok, %ProviderJob{} = job} = fetch_info(bypass, config, unquote(status))

        assert job.state == :error
        assert job.failure_category == unquote(category)
        assert job.failure_detail == unquote(status)
      end
    end

    test "a healthy torrent carries no failure fields", %{bypass: bypass, config: config} do
      assert {:ok, %ProviderJob{} = job} = fetch_info(bypass, config, "downloading")

      assert job.failure_category == nil
      assert job.failure_detail == nil
    end
  end

  describe "get_download_urls/2" do
    test "issues N /unrestrict/link calls and returns URLs in order", %{
      bypass: bypass,
      config: config
    } do
      Bypass.expect(bypass, "POST", "/unrestrict/link", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        link = body |> URI.decode_query() |> Map.get("link")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"download" => "https://direct.example/" <> link}))
      end)

      job = %ProviderJob{
        provider_id: "RD123",
        state: :ready,
        hoster_links: ["a", "b", "c"]
      }

      assert {:ok, urls} = RealDebrid.get_download_urls(config, job)
      assert length(urls) == 3
      assert "https://direct.example/a" in urls
    end
  end

  describe "delete_job/2" do
    test "204 returns :ok", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "DELETE", "/torrents/delete/RD123", fn conn ->
        Plug.Conn.resp(conn, 204, "")
      end)

      assert :ok = RealDebrid.delete_job(config, "RD123")
    end

    test "404 returns :ok (already deleted)", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "DELETE", "/torrents/delete/RD123", fn conn ->
        Plug.Conn.resp(conn, 404, "")
      end)

      assert :ok = RealDebrid.delete_job(config, "RD123")
    end
  end

  describe "list_jobs/2" do
    test "empty input returns empty map", %{config: config} do
      assert {:ok, %{}} = RealDebrid.list_jobs(config, [])
    end

    test "fans out N concurrent get_job calls", %{bypass: bypass, config: config} do
      ids = ["RD1", "RD2", "RD3"]

      Bypass.expect(bypass, "GET", "/torrents/info/RD1", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "RD1",
            "status" => "downloaded",
            "progress" => 100,
            "bytes" => 1
          })
        )
      end)

      Bypass.expect(bypass, "GET", "/torrents/info/RD2", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "RD2",
            "status" => "downloading",
            "progress" => 50,
            "bytes" => 100
          })
        )
      end)

      Bypass.expect(bypass, "GET", "/torrents/info/RD3", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"id" => "RD3", "status" => "queued", "progress" => 0, "bytes" => 0})
        )
      end)

      assert {:ok, jobs} = RealDebrid.list_jobs(config, ids)
      assert map_size(jobs) == 3
      assert %ProviderJob{state: :ready} = jobs["RD1"]
      assert %ProviderJob{state: :downloading} = jobs["RD2"]
      assert %ProviderJob{state: :queued} = jobs["RD3"]
    end
  end

  describe "rate_limit_budget/0" do
    test "returns {250, 60}" do
      assert RealDebrid.rate_limit_budget() == {250, 60}
    end
  end
end
