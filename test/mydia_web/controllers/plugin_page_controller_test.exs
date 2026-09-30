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
      |> post("/plugins/#{@slug}/app/echo?t=#{token}&keep=1", Jason.encode!(%{"a" => 1}))

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
      |> post("/plugins/#{@slug}/app/echo?t=#{token}", raw)

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["body"] == raw
  end

  test "other routes still get parsed body params" do
    conn =
      Plug.Test.conn(:post, "/api/anything", ~s({"a":1}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> MydiaWeb.Plugs.PageBodyBypass.call(
        MydiaWeb.Plugs.PageBodyBypass.init(
          parsers: [:json],
          pass: ["*/*"],
          json_decoder: Jason
        )
      )

    assert conn.body_params == %{"a" => 1}
  end

  test "the token also works as a header", %{conn: conn, token: token} do
    conn =
      conn |> put_req_header("x-mydia-frame-token", token) |> get("/plugins/#{@slug}/app/echo")

    assert conn.status == 200
  end

  test "a missing, forged or foreign-slug token is 401", %{conn: conn, user: user} do
    assert get(conn, "/plugins/#{@slug}/app/echo").status == 401
    assert get(conn, "/plugins/#{@slug}/app/echo?t=nope").status == 401

    other = PluginFrameToken.sign("other-plugin", user.id, "s")
    assert get(conn, "/plugins/#{@slug}/app/echo?t=#{other}").status == 401
  end

  test "a token for a deleted user is 401", %{conn: conn} do
    token = PluginFrameToken.sign(@slug, Ecto.UUID.generate(), "s")
    assert get(conn, "/plugins/#{@slug}/app/echo?t=#{token}").status == 401
  end

  test "a disabled plugin is 404", %{conn: conn, token: token} do
    register(false)
    assert get(conn, "/plugins/#{@slug}/app/echo?t=#{token}").status == 404
  end

  test "a body that is not valid UTF-8 is 415, not a crash", %{conn: conn, token: token} do
    conn =
      conn
      |> put_req_header("content-type", "application/octet-stream")
      |> post("/plugins/#{@slug}/app/echo?t=#{token}", <<0xFF, 0xFE, 0x00>>)

    assert conn.status == 415
  end

  test "an oversized body is 413", %{conn: conn, token: token} do
    conn =
      conn
      |> put_req_header("content-type", "text/plain")
      |> post("/plugins/#{@slug}/app/echo?t=#{token}", String.duplicate("a", 1_048_577))

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

    conn = get(conn, "/plugins/#{@slug}/app/echo?t=#{token}")

    assert conn.status == 503
    assert get_resp_header(conn, "retry-after") != []
    assert conn.resp_body == ""
  end

  test "an unknown page route surfaces the guest's status", %{conn: conn, token: token} do
    conn = get(conn, "/plugins/#{@slug}/app/definitely-missing?t=#{token}")
    assert conn.status in [404, 500]
  end

  test "preflight answers without a token", %{conn: conn} do
    conn = options(conn, "/plugins/#{@slug}/app/echo")
    assert conn.status == 204

    assert get_resp_header(conn, "access-control-allow-headers") == [
             "content-type, x-mydia-frame-token"
           ]
  end
end
