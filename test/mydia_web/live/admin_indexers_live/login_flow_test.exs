defmodule MydiaWeb.AdminIndexersLive.LoginFlowTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.CardigannLoginFixtures

  alias Mydia.Accounts
  alias Mydia.Indexers.{CardigannAuth, CardigannDefinition}
  alias Mydia.Repo

  @yaml """
  id: invented-tracker
  name: Invented Tracker
  description: An invented tracker for tests
  type: private
  language: en-US
  encoding: UTF-8
  links: ["BASE/"]
  caps: {categorymappings: [{id: 1, cat: Movies}], modes: {search: [q]}}
  settings: [{name: username, type: text, label: Username}]
  login:
    method: form
    path: /login.php
    inputs: {username: "{{ .Config.username }}"}
    captcha: {type: image, selector: img.c, input: cap}
  search:
    paths: [{path: /browse.php}]
    rows: {selector: tr}
    fields: {title: {selector: td}, download: {selector: a, attribute: href}, size: {selector: td}, seeders: {selector: td}}
  """

  setup %{conn: conn} do
    unique_id = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        email: "admin_#{unique_id}@example.com",
        username: "admin_#{unique_id}",
        password_hash: "$2b$12$test",
        role: "admin"
      })

    {:ok, token, _claims} = Mydia.Auth.Guardian.encode_and_sign(user)

    conn =
      conn
      |> init_test_session(%{})
      |> put_session(:guardian_default_token, token)
      |> put_req_header("authorization", "Bearer #{token}")

    start_supervised!(Mydia.Indexers.Health)
    Mydia.Indexers.register_adapters()

    bypass = Bypass.open()
    base = "http://localhost:#{bypass.port}"

    d =
      definition(%{"username" => "alice"}, %{
        health_status: "needs_login",
        definition: String.replace(@yaml, "BASE", base)
      })

    {:ok, conn: conn, bypass: bypass, definition: d}
  end

  defp landing(bypass) do
    Bypass.expect(bypass, "GET", "/login.php", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("set-cookie", "PHPSESSID=s1")
      |> Plug.Conn.resp(
        200,
        ~s(<form action="/t"><input name="username"></form><img class="c" src="/c.png">)
      )
    end)

    Bypass.expect(bypass, "GET", "/c.png", fn conn ->
      conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.resp(200, "PNG")
    end)
  end

  test "a needs_login indexer shows a Log in button", %{conn: conn, definition: d} do
    {:ok, view, _} = live(conn, ~p"/admin/indexers")
    assert has_element?(view, "#indexer-login-#{d.id}")
  end

  test "Log in opens the captcha modal and a correct answer logs in", %{
    conn: conn,
    bypass: bypass,
    definition: d
  } do
    landing(bypass)

    Bypass.expect_once(bypass, "POST", "/t", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert URI.decode_query(body)["cap"] == "K7QX"
      conn |> Plug.Conn.put_resp_header("set-cookie", "uid=7") |> Plug.Conn.resp(200, "welcome")
    end)

    {:ok, view, _} = live(conn, ~p"/admin/indexers")
    view |> element("#indexer-login-#{d.id}") |> render_click()
    render_async(view)

    assert has_element?(view, "#indexer-login-modal")
    assert has_element?(view, "#indexer-login-captcha[src^='data:image/png;base64,']")

    view |> form("#indexer-login-form", login: %{captcha: "K7QX"}) |> render_submit()
    render_async(view)

    refute has_element?(view, "#indexer-login-modal")
    # The jar keeps the landing-page session cookie alongside the one set on login.
    assert {:ok, %{cookies: cookies}} = CardigannAuth.get_stored_session(d.id)
    assert "uid=7" in cookies
    assert Repo.get!(CardigannDefinition, d.id).health_status == "healthy"
  end

  test "a rejected answer keeps the modal open with the error and a new image", %{
    conn: conn,
    bypass: bypass,
    definition: d
  } do
    landing(bypass)

    Bypass.expect_once(bypass, "POST", "/t", fn conn -> Plug.Conn.resp(conn, 401, "") end)

    {:ok, view, _} = live(conn, ~p"/admin/indexers")
    view |> element("#indexer-login-#{d.id}") |> render_click()
    render_async(view)
    view |> form("#indexer-login-form", login: %{captcha: "nope"}) |> render_submit()
    render_async(view)

    assert has_element?(view, "#indexer-login-modal .alert-error")
    assert has_element?(view, "#indexer-login-captcha")
  end

  test "Cancel closes the modal", %{conn: conn, bypass: bypass, definition: d} do
    landing(bypass)

    {:ok, view, _} = live(conn, ~p"/admin/indexers")
    view |> element("#indexer-login-#{d.id}") |> render_click()
    render_async(view)
    assert has_element?(view, "#indexer-login-modal")

    view |> element("#indexer-login-cancel") |> render_click()
    refute has_element?(view, "#indexer-login-modal")
  end

  test "closing the modal while the login is in flight drops the result", %{
    conn: conn,
    bypass: bypass,
    definition: d
  } do
    test_pid = self()

    Bypass.stub(bypass, "GET", "/login.php", fn conn ->
      # The client is cancelled mid-request, which kills this handler; don't let
      # Bypass report that as a test failure.
      Process.flag(:trap_exit, true)
      send(test_pid, :landing_hit)
      Process.sleep(300)

      Plug.Conn.resp(
        conn,
        200,
        ~s(<form action="/t"><input name="username"></form><img class="c" src="/c.png">)
      )
    end)

    Bypass.stub(bypass, "GET", "/c.png", fn conn ->
      conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.resp(200, "PNG")
    end)

    {:ok, view, _} = live(conn, ~p"/admin/indexers")
    view |> element("#indexer-login-#{d.id}") |> render_click()
    # Close once the request is really in flight (no modal is rendered yet).
    assert_receive :landing_hit, 2_000
    render_click(view, "indexer_login_close", %{})
    # The cancelled task never reports back, so wait out the slow request instead.
    Process.sleep(500)
    render(view)

    assert Process.alive?(view.pid)
    refute has_element?(view, "#indexer-login-modal")
    assert {:error, _} = CardigannAuth.get_stored_session(d.id)
  end
end
