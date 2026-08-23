defmodule MetadataRelayWeb.GitHubAuthTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn
  import MetadataRelay.Test.GitHubHelpers

  alias MetadataRelay.Repo
  alias MetadataRelayWeb.DashboardAuth

  @endpoint MetadataRelayWeb.Endpoint

  @membership_url "https://api.github.com/user/memberships/orgs/getmydia"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    previous_org = put_dashboard_org("getmydia")

    previous_github =
      put_github_config(client_id: "cid", client_secret: "csecret", repo: "getmydia/mydia")

    on_exit(fn ->
      restore_dashboard_org(previous_org)
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

  test "callback signs in an active org member and honors return_to" do
    stub_successful_github("arsfeld")

    conn =
      build_conn()
      |> init_test_session(oauth_state: "st4te", return_to: "/feedback?focus=abc")
      |> get("/auth/github/callback", %{"code" => "ok", "state" => "st4te"})

    assert redirected_to(conn) == "/feedback?focus=abc"
    assert get_session(conn, :github_login) == "arsfeld"
    assert get_session(conn, :github_token) == "gho_token"
    assert is_integer(get_session(conn, :github_verified_at))
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

  test "callback rejects non-binary code and state params without raising" do
    stub_successful_github("arsfeld")

    for params <- [
          %{"code" => "ok", "state" => ["st4te"]},
          %{"code" => ["ok"], "state" => "st4te"},
          %{"code" => %{"a" => "b"}, "state" => %{"a" => "b"}}
        ] do
      conn =
        build_conn()
        |> init_test_session(oauth_state: "st4te")
        |> get("/auth/github/callback", params)

      assert redirected_to(conn) == "/auth/login?error=failed"
      assert get_session(conn, :github_login) == nil
    end
  end

  test "callback refuses a login that is not an org member" do
    stub_github(membership: Req.Response.new(status: 404, body: %{"message" => "Not Found"}))

    conn =
      build_conn()
      |> init_test_session(oauth_state: "st4te")
      |> get("/auth/github/callback", %{"code" => "ok", "state" => "st4te"})

    assert redirected_to(conn) == "/auth/login?error=denied"
    assert get_session(conn, :github_login) == nil
  end

  test "callback refuses a pending invitation, which is not yet membership" do
    stub_github(
      membership: Req.Response.new(status: 200, body: %{"state" => "pending", "role" => "member"})
    )

    conn =
      build_conn()
      |> init_test_session(oauth_state: "st4te")
      |> get("/auth/github/callback", %{"code" => "ok", "state" => "st4te"})

    assert redirected_to(conn) == "/auth/login?error=denied"
    assert get_session(conn, :github_login) == nil
  end

  test "callback reports an unreachable GitHub separately from a refusal" do
    stub_github(membership: Req.Response.new(status: 500, body: %{}))

    conn =
      build_conn()
      |> init_test_session(oauth_state: "st4te")
      |> get("/auth/github/callback", %{"code" => "ok", "state" => "st4te"})

    assert redirected_to(conn) == "/auth/login?error=unavailable"
    assert get_session(conn, :github_login) == nil
  end

  test "a signed-in session with a fresh check reaches the dashboard without calling GitHub" do
    set_github_adapter(fn _request -> raise "GitHub must not be called for a fresh session" end)

    conn =
      build_conn()
      |> init_test_session(signed_in_session())
      |> get("/feedback")

    assert html_response(conn, 200) =~ "feedback-dashboard"
  end

  test "a stale session is revalidated and refreshed when still a member" do
    stub_github(membership: Req.Response.new(status: 200, body: active_membership()))

    conn =
      build_conn()
      |> init_test_session(signed_in_session(verified_at: stale()))
      |> get("/feedback")

    assert html_response(conn, 200) =~ "feedback-dashboard"
    assert DashboardAuth.verification_fresh?(get_session(conn, :github_verified_at))
  end

  test "a session whose member left the org is turned away once the check goes stale" do
    stub_github(membership: Req.Response.new(status: 404, body: %{"message" => "Not Found"}))

    conn =
      build_conn()
      |> init_test_session(signed_in_session(verified_at: stale()))
      |> get("/feedback")

    assert redirected_to(conn) == "/auth/login?error=denied"
    assert get_session(conn, :github_login) == nil
  end

  test "an unreachable GitHub does not sign out an already verified session" do
    stub_github(membership: Req.Response.new(status: 500, body: %{}))

    conn =
      build_conn()
      |> init_test_session(signed_in_session(verified_at: stale()))
      |> get("/feedback")

    assert html_response(conn, 200) =~ "feedback-dashboard"
    assert get_session(conn, :github_login) == "arsfeld"
  end

  test "sign-out clears the session" do
    conn =
      build_conn()
      |> init_test_session(signed_in_session())
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

  defp signed_in_session(opts \\ []) do
    [
      github_login: "arsfeld",
      github_token: "gho_token",
      github_verified_at: Keyword.get(opts, :verified_at, DashboardAuth.verified_now())
    ]
  end

  # Old enough that the revalidation window has passed.
  defp stale, do: DashboardAuth.verified_now() - 100_000

  defp stub_successful_github(login) do
    stub_github(
      login: login,
      membership: Req.Response.new(status: 200, body: active_membership(login))
    )
  end

  defp stub_github(opts) do
    login = Keyword.get(opts, :login, "arsfeld")
    membership = Keyword.fetch!(opts, :membership)

    set_github_adapter(fn request ->
      case URI.to_string(request.url) do
        "https://github.com/login/oauth/access_token" ->
          {request, Req.Response.new(status: 200, body: %{"access_token" => "gho_token"})}

        "https://api.github.com/user" ->
          {request, Req.Response.new(status: 200, body: %{"login" => login})}

        @membership_url ->
          {request, membership}
      end
    end)
  end
end
