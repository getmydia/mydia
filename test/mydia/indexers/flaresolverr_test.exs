defmodule Mydia.Indexers.FlareSolverrTest do
  # async: false — these tests inject FlareSolverr settings into the global
  # :runtime_config application env, which is read across the app; running them
  # concurrently would race other tests reading the runtime config.
  use ExUnit.Case, async: false

  alias Mydia.Indexers.FlareSolverr
  alias Mydia.Indexers.FlareSolverr.Response

  # Snapshot and restore the cached runtime config around every test so the
  # per-test FlareSolverr config we inject never leaks into other tests.
  setup do
    original = Application.get_env(:mydia, :runtime_config)

    on_exit(fn ->
      if original do
        Application.put_env(:mydia, :runtime_config, original)
      else
        Application.delete_env(:mydia, :runtime_config)
      end
    end)

    :ok
  end

  describe "Response.from_json/1" do
    test "parses successful response" do
      json = %{
        "status" => "ok",
        "message" => "Challenge solved!",
        "solution" => %{
          "url" => "https://example.com/page",
          "status" => 200,
          "headers" => %{"content-type" => "text/html"},
          "response" => "<html>test</html>",
          "cookies" => [
            %{
              "name" => "cf_clearance",
              "value" => "abc123",
              "domain" => ".example.com",
              "path" => "/",
              "expires" => 1_700_000_000.0,
              "httpOnly" => true,
              "secure" => true,
              "sameSite" => "None"
            }
          ],
          "userAgent" => "Mozilla/5.0 Test"
        },
        "startTimestamp" => 1_699_000_000_000,
        "endTimestamp" => 1_699_000_015_000,
        "version" => "3.3.21"
      }

      assert {:ok, response} = Response.from_json(json)
      assert response.status == "ok"
      assert response.message == "Challenge solved!"
      assert response.solution.url == "https://example.com/page"
      assert response.solution.status == 200
      assert response.solution.response == "<html>test</html>"
      assert response.solution.user_agent == "Mozilla/5.0 Test"
      assert response.start_timestamp == 1_699_000_000_000
      assert response.end_timestamp == 1_699_000_015_000
      assert response.version == "3.3.21"
    end

    test "parses cookies correctly" do
      json = %{
        "status" => "ok",
        "solution" => %{
          "url" => "https://example.com",
          "status" => 200,
          "response" => "",
          "cookies" => [
            %{
              "name" => "cf_clearance",
              "value" => "abc123",
              "domain" => ".example.com",
              "path" => "/",
              "httpOnly" => true,
              "secure" => true
            },
            %{
              "name" => "session_id",
              "value" => "xyz789",
              "domain" => "example.com",
              "path" => "/app"
            }
          ],
          "userAgent" => "Mozilla/5.0"
        }
      }

      assert {:ok, response} = Response.from_json(json)
      cookies = Response.cookies(response)

      assert length(cookies) == 2

      [cookie1, cookie2] = cookies
      assert cookie1.name == "cf_clearance"
      assert cookie1.value == "abc123"
      assert cookie1.domain == ".example.com"
      assert cookie1.http_only == true
      assert cookie1.secure == true

      assert cookie2.name == "session_id"
      assert cookie2.value == "xyz789"
      assert cookie2.http_only == false
      assert cookie2.secure == false
    end

    test "returns error for invalid response" do
      assert {:error, _} = Response.from_json(%{})
      assert {:error, _} = Response.from_json(%{"invalid" => "data"})
    end
  end

  describe "Response helper functions" do
    setup do
      json = %{
        "status" => "ok",
        "solution" => %{
          "url" => "https://example.com",
          "status" => 200,
          "response" => "<html>body</html>",
          "cookies" => [
            %{"name" => "a", "value" => "1", "domain" => "ex.com"},
            %{"name" => "b", "value" => "2", "domain" => "ex.com"}
          ],
          "userAgent" => "TestAgent/1.0"
        },
        "startTimestamp" => 1000,
        "endTimestamp" => 2500
      }

      {:ok, response} = Response.from_json(json)
      %{response: response}
    end

    test "body/1 returns HTML body", %{response: response} do
      assert Response.body(response) == "<html>body</html>"
    end

    test "cookies/1 returns cookie list", %{response: response} do
      cookies = Response.cookies(response)
      assert length(cookies) == 2
    end

    test "cookie_header/1 formats cookies as header string", %{response: response} do
      header = Response.cookie_header(response)
      assert header == "a=1; b=2"
    end

    test "user_agent/1 returns user agent", %{response: response} do
      assert Response.user_agent(response) == "TestAgent/1.0"
    end

    test "http_status/1 returns status code", %{response: response} do
      assert Response.http_status(response) == 200
    end

    test "success?/1 returns true for ok status", %{response: response} do
      assert Response.success?(response) == true
    end

    test "success?/1 returns false for error status" do
      {:ok, error_response} = Response.from_json(%{"status" => "error", "message" => "Failed"})
      assert Response.success?(error_response) == false
    end

    test "duration_ms/1 calculates duration", %{response: response} do
      assert Response.duration_ms(response) == 1500
    end
  end

  describe "enabled?/0" do
    test "returns false when not configured" do
      clear_flaresolverr_config()
      refute FlareSolverr.enabled?()
    end

    test "returns false when disabled" do
      put_flaresolverr_config(enabled: false, url: "http://localhost:8191")
      refute FlareSolverr.enabled?()
    end

    test "returns true when enabled with URL" do
      put_flaresolverr_config(enabled: true, url: "http://localhost:8191")
      assert FlareSolverr.enabled?()
    end

    test "returns false when enabled but the URL is nil" do
      put_flaresolverr_config(enabled: true, url: nil)
      refute FlareSolverr.enabled?()
    end

    test "returns false when enabled but the URL is empty" do
      put_flaresolverr_config(enabled: true, url: "")
      refute FlareSolverr.enabled?()
    end
  end

  describe "config/0" do
    test "returns nil when not configured" do
      clear_flaresolverr_config()
      assert FlareSolverr.config() == nil
    end

    test "returns config map when configured" do
      put_flaresolverr_config(
        enabled: true,
        url: "http://localhost:8191",
        timeout: 60_000,
        max_timeout: 120_000
      )

      config = FlareSolverr.config()
      assert config.enabled == true
      assert config.url == "http://localhost:8191"
      assert config.timeout == 60_000
      assert config.max_timeout == 120_000
    end
  end

  describe "get/2" do
    test "returns error when not configured" do
      clear_flaresolverr_config()
      assert {:error, :not_configured} = FlareSolverr.get("https://example.com")
    end

    test "returns error when disabled" do
      put_flaresolverr_config(enabled: false, url: "http://localhost:8191")
      assert {:error, :disabled} = FlareSolverr.get("https://example.com")
    end
  end

  describe "post/2" do
    test "returns error when not configured" do
      clear_flaresolverr_config()
      assert {:error, :not_configured} = FlareSolverr.post("https://example.com")
    end
  end

  # HTTP-level tests using Bypass to exercise real Req.post calls

  describe "health_check/0 via HTTP" do
    setup do
      bypass = Bypass.open()
      put_flaresolverr_config(enabled: true, url: "http://localhost:#{bypass.port}")
      %{bypass: bypass}
    end

    test "returns ok with status, version, and sessions on 200", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"cmd" => "sessions.list"} = Jason.decode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "status" => "ok",
            "version" => "3.3.21",
            "sessions" => ["session-abc"]
          })
        )
      end)

      assert {:ok, result} = FlareSolverr.health_check()
      assert result.status == "ok"
      assert result.version == "3.3.21"
      assert result.sessions == ["session-abc"]
    end

    test "returns http_error on non-200 status", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, Jason.encode!(%{"error" => "internal"}))
      end)

      assert {:error, {:http_error, 500, _body}} = FlareSolverr.health_check()
    end

    test "returns connection_error when service is down", %{bypass: bypass} do
      Bypass.down(bypass)

      assert {:error, {:connection_error, _reason}} = FlareSolverr.health_check()
    end
  end

  describe "health_check/0 gating" do
    # health_check/0 is the saved-config check that status/0 and available?/0
    # build on. Only the admin Test buttons skip the enabled gate, through
    # health_check/1; this pins that the gate itself did not move.
    test "still returns :disabled when the saved config is switched off" do
      put_flaresolverr_config(enabled: false, url: "http://localhost:8191")
      assert {:error, :disabled} = FlareSolverr.health_check()
    end

    test "returns :not_configured when there is no FlareSolverr config" do
      clear_flaresolverr_config()
      assert {:error, :not_configured} = FlareSolverr.health_check()
    end
  end

  describe "health_check/1" do
    test "probes the given URL even while FlareSolverr is disabled" do
      bypass = Bypass.open()
      put_flaresolverr_config(enabled: false, url: nil)

      Bypass.expect_once(bypass, "POST", "/v1", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"cmd" => "sessions.list"} = Jason.decode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"status" => "ok", "version" => "3.3.21", "sessions" => []})
        )
      end)

      assert {:ok, %{version: "3.3.21", sessions: []}} =
               FlareSolverr.health_check("http://localhost:#{bypass.port}")
    end

    test "returns connection_error when nothing answers at the given URL" do
      bypass = Bypass.open()
      Bypass.down(bypass)

      assert {:error, {:connection_error, _reason}} =
               FlareSolverr.health_check("http://localhost:#{bypass.port}")
    end

    test "rejects anything but an absolute http(s) URL without making a request" do
      for url <- [nil, "", "   ", "flaresolverr:8191", "ftp://flaresolverr.test", "http://"] do
        assert {:error, :invalid_url} = FlareSolverr.health_check(url),
               "expected #{inspect(url)} to be rejected"
      end
    end
  end

  describe "get/2 via HTTP" do
    setup do
      bypass = Bypass.open()

      put_flaresolverr_config(
        enabled: true,
        url: "http://localhost:#{bypass.port}",
        timeout: 30_000,
        max_timeout: 60_000
      )

      %{bypass: bypass}
    end

    test "returns parsed Response on successful challenge solve", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["cmd"] == "request.get"
        assert decoded["url"] == "https://protected.example.com"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "status" => "ok",
            "message" => "Challenge solved!",
            "solution" => %{
              "url" => "https://protected.example.com",
              "status" => 200,
              "response" => "<html>solved</html>",
              "cookies" => [
                %{"name" => "cf_clearance", "value" => "token123", "domain" => ".example.com"}
              ],
              "userAgent" => "Mozilla/5.0 Test"
            },
            "startTimestamp" => 1_000_000,
            "endTimestamp" => 1_005_000,
            "version" => "3.3.21"
          })
        )
      end)

      assert {:ok, %Response{} = response} = FlareSolverr.get("https://protected.example.com")
      assert response.status == "ok"
      assert Response.body(response) == "<html>solved</html>"
      assert Response.user_agent(response) == "Mozilla/5.0 Test"
    end

    test "returns challenge_failed error on error response", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "status" => "error",
            "message" => "Challenge detection failed after 60s"
          })
        )
      end)

      assert {:error, {:challenge_failed, "Challenge detection failed after 60s"}} =
               FlareSolverr.get("https://protected.example.com")
    end

    test "returns http_error on 500", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, Jason.encode!(%{"error" => "server error"}))
      end)

      assert {:error, {:http_error, 500, _}} =
               FlareSolverr.get("https://protected.example.com")
    end

    test "returns connection_error when service is down", %{bypass: bypass} do
      Bypass.down(bypass)

      assert {:error, {:connection_error, _}} =
               FlareSolverr.get("https://protected.example.com")
    end
  end

  describe "available?/0 via HTTP" do
    setup do
      bypass = Bypass.open()
      put_flaresolverr_config(enabled: true, url: "http://localhost:#{bypass.port}")
      %{bypass: bypass}
    end

    test "returns true when service is healthy", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "status" => "ok",
            "version" => "3.3.21",
            "sessions" => []
          })
        )
      end)

      assert FlareSolverr.available?()
    end

    test "returns false when service is down", %{bypass: bypass} do
      Bypass.down(bypass)

      refute FlareSolverr.available?()
    end
  end

  ## Helpers — inject FlareSolverr settings into the layered runtime config.

  defp put_flaresolverr_config(attrs) do
    fs = struct(Mydia.Config.Schema.FlareSolverr, attrs)
    Application.put_env(:mydia, :runtime_config, %{current_runtime_config() | flaresolverr: fs})
  end

  # "Not configured": no FlareSolverr embed at all, so get_config/0 reports
  # {:error, :not_configured} (config/0 returns nil, get/post return that error).
  defp clear_flaresolverr_config do
    Application.put_env(:mydia, :runtime_config, %{current_runtime_config() | flaresolverr: nil})
  end

  defp current_runtime_config do
    case Application.get_env(:mydia, :runtime_config) do
      %Mydia.Config.Schema{} = config -> config
      _ -> Mydia.Config.Schema.defaults()
    end
  end
end
