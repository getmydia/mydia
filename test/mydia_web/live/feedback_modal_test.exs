defmodule MydiaWeb.FeedbackModalTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MetadataCacheHelpers

  alias Mydia.Accounts
  alias Mydia.Settings

  setup %{conn: conn} do
    # Every test here mounts "/", and DashboardLive.Index unconditionally
    # loads both trending rails on connected mount. stub_dashboard_requests/1
    # below additionally covers the 3 tests that override metadata_relay_url
    # for their own Bypass, but warming the cache here protects every test in
    # the file regardless of which relay url happens to be configured at
    # mount time — a cache hit never reaches the network at all (#530).
    warm_trending_cache(:movie, [])
    warm_trending_cache(:tv_show, [])

    unique_id = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        email: "feedback_#{unique_id}@example.com",
        username: "feedback_#{unique_id}",
        password_hash: "$2b$12$test",
        role: "admin"
      })

    {:ok, token, _claims} = Mydia.Auth.Guardian.encode_and_sign(user)

    original_relay_url = System.get_env("METADATA_RELAY_URL")

    on_exit(fn ->
      if original_relay_url do
        System.put_env("METADATA_RELAY_URL", original_relay_url)
      else
        System.delete_env("METADATA_RELAY_URL")
      end
    end)

    conn =
      conn
      |> init_test_session(%{})
      |> put_session(:guardian_default_token, token)
      |> put_req_header("authorization", "Bearer #{token}")

    %{conn: conn, user: user}
  end

  test "renders sidebar entry and privacy disclosure", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "Send feedback"
    assert html =~ "phx-click=\"open_feedback_modal\""
    assert html =~ "start a GitHub discussion"
    assert html =~ "https://github.com/getmydia/mydia/discussions/new/choose"
    assert html =~ "Your message and optional contact info are sent to the Mydia developer"
  end

  test "clicking the sidebar entry opens the modal", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> element("#sidebar-send-feedback")
      |> render_click()

    assert html =~ ~s(id="feedback-modal")
    assert html =~ ~s(open)
  end

  test "submitting without type rerenders validation error and does not post", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#sidebar-send-feedback")
    |> render_click()

    html =
      view
      |> form("#feedback-form", %{feedback: %{message: "Something broke"}})
      |> render_submit()

    assert html =~ "can&#39;t be blank"
  end

  test "submitting without message rerenders validation error", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#sidebar-send-feedback")
    |> render_click()

    html =
      view
      |> form("#feedback-form", %{feedback: %{type: "bug", message: ""}})
      |> render_submit()

    assert html =~ "can&#39;t be blank"
  end

  test "message longer than 4096 bytes is rejected", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#sidebar-send-feedback")
    |> render_click()

    html =
      view
      |> form("#feedback-form", %{
        feedback: %{type: "bug", message: String.duplicate("a", 4097)}
      })
      |> render_submit()

    assert html =~ "should be at most 4096 bytes"
  end

  test "multi-byte message longer than 4096 bytes is rejected", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#sidebar-send-feedback")
    |> render_click()

    html =
      view
      |> form("#feedback-form", %{
        feedback: %{type: "bug", message: String.duplicate("🎬", 1025)}
      })
      |> render_submit()

    assert html =~ "should be at most 4096 bytes"
    assert html =~ "4100 / 4096 bytes"
  end

  test "valid submit posts feedback, closes modal, and flashes thanks", %{conn: conn} do
    bypass = Bypass.open()
    System.put_env("METADATA_RELAY_URL", endpoint_url(bypass))
    stub_dashboard_requests(bypass)

    Bypass.expect_once(bypass, "POST", "/feedback", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)

      assert payload["type"] == "idea"
      assert payload["message"] == "Add watch party mode"
      assert payload["contact"] == "user@example.com"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(201, Jason.encode!(%{id: "feedback-1"}))
    end)

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#sidebar-send-feedback")
    |> render_click()

    html =
      view
      |> form("#feedback-form", %{
        feedback: %{
          type: "idea",
          message: "Add watch party mode",
          contact: "user@example.com"
        }
      })
      |> render_submit()

    assert html =~ "Thanks, feedback sent."
    refute html =~ ~s(<dialog id="feedback-modal" class="modal" open)
  end

  test "rate limit preserves the draft", %{conn: conn} do
    bypass = Bypass.open()
    System.put_env("METADATA_RELAY_URL", endpoint_url(bypass))
    stub_dashboard_requests(bypass)

    Bypass.expect_once(bypass, "POST", "/feedback", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "60")
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(429, Jason.encode!(%{error: "Too many requests"}))
    end)

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#sidebar-send-feedback")
    |> render_click()

    html =
      view
      |> form("#feedback-form", %{feedback: %{type: "bug", message: "Keep this draft"}})
      |> render_submit()

    assert html =~ "Feedback is rate limited"
    assert html =~ "Keep this draft"
  end

  test "old relay unavailable response preserves the page", %{conn: conn} do
    bypass = Bypass.open()
    System.put_env("METADATA_RELAY_URL", endpoint_url(bypass))
    stub_dashboard_requests(bypass)

    Bypass.expect_once(bypass, "POST", "/feedback", fn conn ->
      Plug.Conn.resp(conn, 404, "Not found")
    end)

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#sidebar-send-feedback")
    |> render_click()

    html =
      view
      |> form("#feedback-form", %{feedback: %{type: "bug", message: "Keep this draft"}})
      |> render_submit()

    assert html =~ "Feedback service is temporarily unavailable"
    assert html =~ "Dashboard"
  end

  test "feedback disabled removes the sidebar entry and modal markup", %{conn: conn} do
    {:ok, _setting} =
      Settings.create_config_setting(%{
        key: "feedback.enabled",
        value: "false",
        category: :feedback
      })

    {:ok, _view, html} = live(conn, ~p"/")

    refute html =~ "phx-click=\"open_feedback_modal\""
    refute html =~ "feedback-modal"
  end

  test "login route does not render feedback markup", %{conn: conn} do
    html =
      conn
      |> recycle()
      |> get(~p"/auth/login")
      |> html_response(200)

    refute html =~ "phx-click=\"open_feedback_modal\""
    refute html =~ "feedback-modal"
  end

  defp endpoint_url(bypass), do: "http://localhost:#{bypass.port}"

  defp stub_dashboard_requests(bypass) do
    for path <- ["/tmdb/movies/trending", "/tmdb/tv/trending"] do
      Bypass.stub(bypass, "GET", path, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{results: []}))
      end)
    end
  end
end
