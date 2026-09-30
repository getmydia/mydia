defmodule MydiaWeb.PluginPageControllerTest do
  use MydiaWeb.ConnCase, async: false

  alias Mydia.Plugins.Host
  alias Mydia.Plugins.HostFunctions
  alias Mydia.Plugins.Plugin
  alias Mydia.Plugins.Registry
  alias Mydia.Plugins.SingleFlight
  alias MydiaWeb.PluginFrameToken

  @fixture Path.expand("../../support/fixtures/plugins/page_fixture.wasm", __DIR__)
  @slug "page-fixture"

  setup do
    {:ok, _} =
      Mydia.Settings.create_plugin_config(%{
        slug: @slug,
        name: "Page Fixture",
        version: "0.0.0",
        source_url: "test",
        manifest: %{"slug" => @slug, "name" => "Page Fixture", "version" => "0.0.0"},
        granted_capabilities: %{"surfaces:page" => []},
        enabled: true
      })

    register(true)

    {:ok, _} =
      Host.start_plugin(@slug, File.read!(@fixture), imports: HostFunctions.imports_for(@slug))

    on_exit(fn ->
      Host.stop_plugin(@slug)
      Registry.unregister(@slug)
    end)

    user = create_test_user()
    {:ok, user: user, token: PluginFrameToken.sign(@slug, user.id, "sess-1")}
  end

  defp register(enabled) do
    Registry.register(@slug, %Plugin{
      slug: @slug,
      name: "Page Fixture",
      enabled: enabled,
      granted_capabilities: %{"surfaces:page" => []},
      page: %{"title" => "Fixture", "icon" => "hero-sparkles"}
    })
  end

  test "serves the guest response with hardened headers", %{conn: conn, user: user, token: token} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("cookie", "should=not-pass")
      |> post(
        "/plugins/#{@slug}/app/echo?frame_token=#{token}&keep=1",
        Jason.encode!(%{"a" => 1})
      )

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["user_id"] == user.id
    assert body["session_id"] == "sess-1"
    assert body["query"] == "keep=1"
    assert body["path"] == "/echo"

    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "frame-ancestors 'self'"
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    assert get_resp_header(conn, "set-cookie") == []
  end

  test "a JSON POST body reaches the guest byte for byte", %{conn: conn, token: token} do
    raw = ~s({ "b":2,\n  "a" : [1, 2,  3] , "z":"\\u00e9"}  )

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/plugins/#{@slug}/app/echo?frame_token=#{token}", raw)

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["body"] == raw
  end

  test "other routes still get parsed body params" do
    conn =
      Plug.Test.conn(:post, "/api/anything", ~s({"a":1}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> parse()

    assert conn.body_params == %{"a" => 1}
  end

  test "look-alike paths do not bypass parsing" do
    for path <- ["/plugins/x/appx", "/plugins/x/app%2Fy", "/plugins/app", "/other/plugins/x/app"] do
      conn =
        Plug.Test.conn(:post, path, ~s({"a":1}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> parse()

      assert conn.body_params == %{"a" => 1}, path
    end

    conn =
      Plug.Test.conn(:post, "/plugins/x/app/echo", ~s({"a":1}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> parse()

    refute conn.body_params == %{"a" => 1}
  end

  defp parse(conn) do
    opts =
      MydiaWeb.Plugs.UnlessPluginPage.init(
        plug: Plug.Parsers,
        opts: [parsers: [:json], pass: ["*/*"], json_decoder: Jason]
      )

    MydiaWeb.Plugs.UnlessPluginPage.call(conn, opts)
  end

  test "the token also works as a header", %{conn: conn, token: token} do
    conn =
      conn |> put_req_header("x-mydia-frame-token", token) |> get("/plugins/#{@slug}/app/echo")

    assert conn.status == 200
  end

  test "a missing, forged or foreign-slug token is 401", %{conn: conn, user: user} do
    assert get(conn, "/plugins/#{@slug}/app/echo").status == 401
    assert get(conn, "/plugins/#{@slug}/app/echo?frame_token=nope").status == 401

    other = PluginFrameToken.sign("other-plugin", user.id, "s")
    assert get(conn, "/plugins/#{@slug}/app/echo?frame_token=#{other}").status == 401
  end

  test "a token for a deleted user is 401", %{conn: conn} do
    token = PluginFrameToken.sign(@slug, Ecto.UUID.generate(), "s")
    assert get(conn, "/plugins/#{@slug}/app/echo?frame_token=#{token}").status == 401
  end

  test "a disabled plugin is 404", %{conn: conn, token: token} do
    register(false)
    assert get(conn, "/plugins/#{@slug}/app/echo?frame_token=#{token}").status == 404
  end

  test "a body that is not valid UTF-8 is 415, not a crash", %{conn: conn, token: token} do
    conn =
      conn
      |> put_req_header("content-type", "application/octet-stream")
      |> post("/plugins/#{@slug}/app/echo?frame_token=#{token}", <<0xFF, 0xFE, 0x00>>)

    assert conn.status == 415
  end

  test "an oversized body is 413", %{conn: conn, token: token} do
    conn =
      conn
      |> put_req_header("content-type", "text/plain")
      |> post("/plugins/#{@slug}/app/echo?frame_token=#{token}", String.duplicate("a", 1_048_577))

    assert conn.status == 413
  end

  test "a busy plugin is 503 with Retry-After and no detail", %{
    conn: conn,
    user: user,
    token: token
  } do
    lock = "#{@slug}:user:#{user.id}"
    assert SingleFlight.acquire(lock, :skip) == :ok
    on_exit(fn -> SingleFlight.release(lock) end)

    conn = get(conn, "/plugins/#{@slug}/app/echo?frame_token=#{token}")

    assert conn.status == 503
    assert get_resp_header(conn, "retry-after") != []
    assert conn.resp_body == ""
  end

  test "an unknown page route surfaces the guest's status", %{conn: conn, token: token} do
    conn = get(conn, "/plugins/#{@slug}/app/definitely-missing?frame_token=#{token}")
    assert conn.status in [404, 500]
  end

  test "preflight answers without a token", %{conn: conn} do
    conn = options(conn, "/plugins/#{@slug}/app/echo")
    assert conn.status == 204

    assert get_resp_header(conn, "access-control-allow-headers") == [
             "content-type, x-mydia-frame-token"
           ]
  end

  describe "hardening" do
    test "every response carries a sandbox directive, errors included", %{
      conn: conn,
      token: token
    } do
      ok = get(conn, "/plugins/#{@slug}/app/echo?frame_token=#{token}")
      denied = get(conn, "/plugins/#{@slug}/app/echo")

      for c <- [ok, denied] do
        assert [csp] = get_resp_header(c, "content-security-policy")
        assert csp =~ "sandbox allow-scripts allow-forms"
        refute csp =~ "allow-same-origin"
      end

      assert denied.status == 401
    end

    test "a null-origin preflight for the token header succeeds without credentials", %{
      conn: conn
    } do
      conn =
        conn
        |> put_req_header("origin", "null")
        |> put_req_header("access-control-request-method", "POST")
        |> put_req_header("access-control-request-headers", "x-mydia-frame-token, content-type")
        |> options("/plugins/#{@slug}/app/echo")

      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "access-control-allow-credentials") == []
      assert [headers] = get_resp_header(conn, "access-control-allow-headers")
      assert headers =~ "x-mydia-frame-token"
    end

    test "a null-origin response is readable and sends no credentials", %{
      conn: conn,
      token: token
    } do
      conn =
        conn
        |> put_req_header("origin", "null")
        |> put_req_header("x-mydia-frame-token", token)
        |> get("/plugins/#{@slug}/app/echo")

      assert conn.status == 200
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "access-control-allow-credentials") == []
    end

    test "an expired token is 401", %{conn: conn, user: user} do
      claims = %{
        slug: @slug,
        user_id: user.id,
        session_id: "s",
        credential:
          Map.fetch!(
            elem(PluginFrameToken.verify(PluginFrameToken.sign(@slug, user.id, "s")), 1),
            :credential
          )
      }

      old =
        Phoenix.Token.sign(MydiaWeb.Endpoint, "plugin frame", claims,
          signed_at: System.system_time(:second) - 2 * 60 * 60
        )

      assert get(conn, "/plugins/#{@slug}/app/echo?frame_token=#{old}").status == 401
    end

    test "a password change invalidates outstanding tokens", %{
      conn: conn,
      user: user,
      token: token
    } do
      assert get(conn, "/plugins/#{@slug}/app/echo?frame_token=#{token}").status == 200

      user
      |> Ecto.Changeset.change(password_hash: "a-different-hash")
      |> Mydia.Repo.update!()

      assert get(conn, "/plugins/#{@slug}/app/echo?frame_token=#{token}").status == 401
    end

    test "a percent-encoded token key is accepted but never reaches the guest", %{
      conn: conn,
      token: token
    } do
      conn =
        get(conn, "/plugins/#{@slug}/app/echo?%66rame_token=#{token}&a=%41&frame_token=#{token}")

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["query"] == "a=%41"
    end

    test "hostile guest headers are dropped and cache-control is forced", %{
      conn: conn,
      token: token
    } do
      conn = get(conn, "/plugins/#{@slug}/app/headers?frame_token=#{token}")

      assert conn.status == 200
      assert conn.resp_body == "hostile"
      assert get_resp_header(conn, "set-cookie") == []
      assert get_resp_header(conn, "x-injected") == []
      assert get_resp_header(conn, "x-custom") == []
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "frame-ancestors 'self'"
      refute csp =~ "default-src *"
    end

    test "a missing content-type gets a safe default", %{conn: conn, token: token} do
      conn = get(conn, "/plugins/#{@slug}/app/no-content-type?frame_token=#{token}")
      assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    end

    test "the request cookie is not forwarded to the guest", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("cookie", "_mydia_key=secret")
        |> put_req_header("authorization", "Bearer abc")
        |> put_req_header("accept-language", "en")
        |> get("/plugins/#{@slug}/app/echo?frame_token=#{token}")

      headers = Jason.decode!(conn.resp_body)["headers"]
      assert headers =~ "accept-language:en"
      refute headers =~ "cookie"
      refute headers =~ "secret"
      refute headers =~ "authorization"
    end
  end
end
