defmodule MetadataRelayWeb.GitHubAuthTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn
  import MetadataRelay.Test.GitHubHelpers

  alias MetadataRelay.Repo

  @endpoint MetadataRelayWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    previous_users = Application.get_env(:metadata_relay, :dashboard_github_users)

    previous_github =
      put_github_config(client_id: "cid", client_secret: "csecret", repo: "getmydia/mydia")

    Application.put_env(:metadata_relay, :dashboard_github_users, ["arsfeld"])

    on_exit(fn ->
      case previous_users do
        nil -> Application.delete_env(:metadata_relay, :dashboard_github_users)
        value -> Application.put_env(:metadata_relay, :dashboard_github_users, value)
      end

      restore_github_config(previous_github)
      clear_github_adapter()
    end)

    :ok
  end

  test "GET /feedback redirects to sign-in instead of prompting for basic auth" do
    conn = get(build_conn(), "/feedback")

    assert redirected_to(conn) == "/auth/login"
    assert get_resp_header(conn, "www-authenticate") == []
  end

  test "GET /errors redirects to sign-in" do
    conn = get(build_conn(), "/errors")

    assert redirected_to(conn) == "/auth/login"
  end

  test "GET /auth/github redirects to GitHub and stores the state" do
    conn = get(build_conn(), "/auth/github")

    location = redirected_to(conn, 302)
    assert String.starts_with?(location, "https://github.com/login/oauth/authorize?")

    params = location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert params["client_id"] == "cid"
    assert params["state"] == get_session(conn, :oauth_state)
  end

  test "callback signs in an allowlisted user and honors return_to" do
    stub_successful_github("arsfeld")

    conn =
      build_conn()
      |> init_test_session(oauth_state: "st4te", return_to: "/feedback?focus=abc")
      |> get("/auth/github/callback", %{"code" => "ok", "state" => "st4te"})

    assert redirected_to(conn) == "/feedback?focus=abc"
    assert get_session(conn, :github_login) == "arsfeld"
    assert get_session(conn, :github_token) == "gho_token"
  end

  test "callback rewrites an off-site return_to" do
    stub_successful_github("arsfeld")

    conn =
      build_conn()
      |> init_test_session(oauth_state: "st4te", return_to: "//evil.example.com")
      |> get("/auth/github/callback", %{"code" => "ok", "state" => "st4te"})

    assert redirected_to(conn) == "/feedback"
  end

  test "callback rejects a mismatched state without signing in" do
    stub_successful_github("arsfeld")

    conn =
      build_conn()
      |> init_test_session(oauth_state: "expected")
      |> get("/auth/github/callback", %{"code" => "ok", "state" => "attacker"})

    assert redirected_to(conn) == "/auth/login?error=failed"
    assert get_session(conn, :github_login) == nil
  end

  test "callback rejects a missing state without signing in" do
    stub_successful_github("arsfeld")

    conn =
      build_conn()
      |> init_test_session(%{})
      |> get("/auth/github/callback", %{"code" => "ok", "state" => "anything"})

    assert redirected_to(conn) == "/auth/login?error=failed"
    assert get_session(conn, :github_login) == nil
  end

  test "callback refuses a login outside the allowlist" do
    stub_successful_github("stranger")

    conn =
      build_conn()
      |> init_test_session(oauth_state: "st4te")
      |> get("/auth/github/callback", %{"code" => "ok", "state" => "st4te"})

    assert redirected_to(conn) == "/auth/login?error=denied"
    assert get_session(conn, :github_login) == nil
  end

  test "a signed-in session reaches the dashboard" do
    conn =
      build_conn()
      |> init_test_session(github_login: "arsfeld", github_token: "gho_token")
      |> get("/feedback")

    assert html_response(conn, 200) =~ "feedback-dashboard"
  end

  test "a session whose login left the allowlist is turned away" do
    Application.put_env(:metadata_relay, :dashboard_github_users, ["someone-else"])

    conn =
      build_conn()
      |> init_test_session(github_login: "arsfeld", github_token: "gho_token")
      |> get("/feedback")

    assert redirected_to(conn) == "/auth/login"
  end

  test "sign-out clears the session" do
    conn =
      build_conn()
      |> init_test_session(github_login: "arsfeld", github_token: "gho_token")
      |> post("/auth/logout")

    assert redirected_to(conn) == "/auth/login"
    assert get_session(conn, :github_login) == nil
  end

  test "a successful callback consumes the one-time oauth state" do
    stub_successful_github("arsfeld")

    conn =
      build_conn()
      |> init_test_session(oauth_state: "st4te", return_to: "/feedback")
      |> get("/auth/github/callback", %{"code" => "ok", "state" => "st4te"})

    assert get_session(conn, :github_login) == "arsfeld"
    assert get_session(conn, :oauth_state) == nil
    assert get_session(conn, :return_to) == nil
  end

  defp stub_successful_github(login) do
    set_github_adapter(fn request ->
      case URI.to_string(request.url) do
        "https://github.com/login/oauth/access_token" ->
          {request, Req.Response.new(status: 200, body: %{"access_token" => "gho_token"})}

        "https://api.github.com/user" ->
          {request, Req.Response.new(status: 200, body: %{"login" => login})}
      end
    end)
  end
end
