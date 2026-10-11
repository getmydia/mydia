defmodule Mydia.Indexers.Cardigann.SessionManagerTest do
  use Mydia.DataCase, async: false

  import Mydia.CardigannLoginFixtures

  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.Cardigann.SessionManager
  alias Mydia.Indexers.{CardigannAuth, CardigannDefinition}

  setup do
    bypass = Bypass.open()
    base = "http://localhost:#{bypass.port}"
    Phoenix.PubSub.subscribe(Mydia.PubSub, SessionManager.topic())
    {:ok, bypass: bypass, base: base}
  end

  defp post_login(bypass, cookie) do
    Bypass.expect_once(bypass, "POST", "/login.php", fn conn ->
      conn |> Plug.Conn.put_resp_header("set-cookie", cookie) |> Plug.Conn.resp(200, "ok")
    end)
  end

  defp redirect do
    {:error,
     Error.search_failed("Redirected (HTTP 302) to /login.php and the redirect was not followed")}
  end

  test "reuses a stored session without logging in", %{base: base} do
    d = definition(%{"username" => "a", "password" => "b"})
    {:ok, _} = CardigannAuth.store_session(d.id, ["uid=1"])

    assert {:ok, %{cookies: ["uid=1"]}} = SessionManager.user_config(parsed(base, %{}), d)
  end

  test "logs in once and retries when the search comes back logged out", %{
    bypass: bypass,
    base: base
  } do
    d = definition(%{"username" => "a", "password" => "b"})
    {:ok, _} = CardigannAuth.store_session(d.id, ["uid=old"])
    post_login(bypass, "uid=new")

    {:ok, agent} =
      Agent.start_link(fn ->
        [
          redirect(),
          {:ok, %{status: 200, body: "{}", headers: %{"content-type" => ["application/json"]}}}
        ]
      end)

    search = fn user_config ->
      Agent.get_and_update(agent, fn [h | t] -> {{h, user_config}, t} end)
    end

    assert {{:ok, _}, %{cookies: ["uid=new"]}} =
             SessionManager.with_session(parsed(base, %{}), d, search)

    assert {:ok, %{cookies: ["uid=new"]}} = CardigannAuth.get_stored_session(d.id)
  end

  test "a second logged-out response is an authentication error", %{bypass: bypass, base: base} do
    d = definition(%{"username" => "a", "password" => "b"})
    {:ok, _} = CardigannAuth.store_session(d.id, ["uid=old"])
    post_login(bypass, "uid=new")

    assert {:error, %Error{type: :authentication_failed}} =
             SessionManager.with_session(parsed(base, %{}), d, fn _ -> redirect() end)
  end

  test "a captcha at re-login marks needs_login and broadcasts", %{bypass: bypass, base: base} do
    d = definition(%{"username" => "a"})

    Bypass.expect_once(bypass, "GET", "/login.php", fn conn ->
      Plug.Conn.resp(
        conn,
        200,
        ~s(<form action="/t"><input name="u"></form><img class="c" src="/c.png">)
      )
    end)

    Bypass.expect_once(bypass, "GET", "/c.png", fn conn -> Plug.Conn.resp(conn, 200, "img") end)

    parsed =
      parsed(base, %{method: "form", captcha: %{type: "image", selector: "img.c", input: "cap"}})

    assert {:error, %Error{type: :login_required}} = SessionManager.user_config(parsed, d)
    assert Repo.get!(CardigannDefinition, d.id).health_status == "needs_login"
    assert_receive {:cardigann_health_changed, id} when id == d.id
  end

  test "needs_login indexers are skipped without a request", %{base: base} do
    d = definition(%{}, %{health_status: "needs_login"})

    assert {:error, %Error{type: :login_required}} =
             SessionManager.user_config(parsed(base, %{method: "form"}), d)
  end

  test "an anonymous definition needs no session", %{base: base} do
    d = definition(%{})
    assert {:ok, %{}} = SessionManager.user_config(%{parsed(base, %{}) | login: nil}, d)
  end
end
