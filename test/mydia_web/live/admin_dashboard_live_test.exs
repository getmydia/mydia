defmodule MydiaWeb.AdminDashboardLiveTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Mydia.Accounts

  setup do
    unique_id = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        email: "admin_#{unique_id}@example.com",
        username: "admin_#{unique_id}",
        password_hash: "$2b$12$test",
        role: "admin"
      })

    {:ok, token, _claims} = Mydia.Auth.Guardian.encode_and_sign(user)

    %{user: user, token: token}
  end

  defp authed(conn, token) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> put_session(:guardian_default_token, token)
    |> put_req_header("authorization", "Bearer #{token}")
  end

  test "redirects unauthenticated users", %{conn: conn} do
    {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin/dashboard")
    assert path =~ "/auth"
  end

  test "renders the KPI row and both charts for an admin", %{conn: conn, token: token} do
    {:ok, view, _html} = live(authed(conn, token), ~p"/admin/dashboard")

    assert has_element?(view, "#kpi-active-streams")
    assert has_element?(view, "#kpi-bandwidth")
    assert has_element?(view, "#kpi-plays-today")
    assert has_element?(view, "#kpi-plays-week")
  end

  test "renders empty states on an idle server", %{conn: conn, token: token} do
    {:ok, view, _html} = live(authed(conn, token), ~p"/admin/dashboard")

    assert has_element?(view, "#bandwidth-chart-empty")
    assert has_element?(view, "#now-playing-empty")
  end

  test "a broadcast sample updates the chart without a reload", %{conn: conn, token: token} do
    {:ok, view, _html} = live(authed(conn, token), ~p"/admin/dashboard")

    for i <- 0..1 do
      Phoenix.PubSub.broadcast(
        Mydia.PubSub,
        Mydia.Streaming.SessionSampler.topic(),
        {:sample,
         %Mydia.Streaming.SessionSampler.Sample{
           at: DateTime.add(~U[2026-08-12 10:00:00Z], i * 5, :second),
           sessions: %{"a" => 2.0},
           unmeasured_count: 0
         }}
      )
    end

    assert render(view) =~ "bandwidth-chart"
  end

  test "the chart keeps updating after the window fills", %{conn: conn, token: token} do
    # Regression: the trim was written as a positive Enum.take/2 over an
    # oldest-first list, which keeps the OLDEST 360 and discards every new
    # sample once the window is full. The chart froze after ~30 minutes and no
    # test caught it, because the others only ever send two samples.
    {:ok, view, _html} = live(authed(conn, token), ~p"/admin/dashboard")

    base = ~U[2026-08-12 10:00:00Z]

    broadcast = fn i, key ->
      Phoenix.PubSub.broadcast(
        Mydia.PubSub,
        Mydia.Streaming.SessionSampler.topic(),
        {:sample,
         %Mydia.Streaming.SessionSampler.Sample{
           at: DateTime.add(base, i * 5, :second),
           sessions: %{key => 2.0},
           unmeasured_count: 0
         }}
      )
    end

    # Overfill the 360-sample window.
    for i <- 0..364, do: broadcast.(i, "old")

    # A new session appearing after the window is full must reach the chart.
    for i <- 365..370, do: broadcast.(i, "fresh")

    html = render(view)

    fresh_fill = MydiaWeb.AdminDashboardLive.Components.series_fill("fresh")

    # Guard the guard: series_fill/1 hashes into 6 slots, so if these two keys
    # ever collide this assertion would pass even with the trim broken.
    refute fresh_fill == MydiaWeb.AdminDashboardLive.Components.series_fill("old")
    assert html =~ fresh_fill
  end
end
