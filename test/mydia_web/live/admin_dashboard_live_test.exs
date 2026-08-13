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

  describe "background transcodes" do
    defp insert_job(media_file, user, type, status) do
      %Mydia.Downloads.TranscodeJob{}
      |> Mydia.Downloads.TranscodeJob.changeset(%{
        media_file_id: media_file.id,
        user_id: user.id,
        type: type,
        status: status,
        resolution: "1080p",
        progress: 0.5,
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Mydia.Repo.insert!()
    end

    test "a download job is listed", %{conn: conn, token: token, user: user} do
      movie = Mydia.MediaFixtures.media_item_fixture(%{type: "movie", title: "Arrival"})
      media_file = Mydia.MediaFixtures.media_file_fixture(%{media_item_id: movie.id})

      insert_job(media_file, user, "download", "transcoding")

      {:ok, view, _html} = live(authed(conn, token), ~p"/admin/dashboard")

      assert has_element?(view, "#background-transcodes")
    end

    test "a playback job is not listed, so viewers are not counted twice", %{
      conn: conn,
      token: token,
      user: user
    } do
      # Both session types insert a TranscodeJob of type stream/direct. Those
      # already show as now-playing cards; listing them here too is the double
      # count the old Status tab had.
      movie = Mydia.MediaFixtures.media_item_fixture(%{type: "movie", title: "Arrival"})
      media_file = Mydia.MediaFixtures.media_file_fixture(%{media_item_id: movie.id})

      insert_job(media_file, user, "stream", "transcoding")

      {:ok, view, _html} = live(authed(conn, token), ~p"/admin/dashboard")

      refute has_element?(view, "#background-transcodes")
    end
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

  # Regression: on a TV library the dashboard reported nobody watching while a
  # stream was running, because an episode's media file carries `episode_id`
  # with `media_item_id` NULL and the session list required the latter.
  test "an episode stream appears in now playing", %{conn: conn, token: token} do
    show =
      Mydia.MediaFixtures.media_item_fixture(%{type: "tv_show", title: "House of the Dragon"})

    episode = Mydia.MediaFixtures.episode_fixture(%{media_item_id: show.id})
    media_file = Mydia.MediaFixtures.media_file_fixture(%{episode_id: episode.id})
    viewer = Mydia.AccountsFixtures.user_fixture()

    {:ok, _pid, :started} =
      Mydia.Streaming.HlsSessionSupervisor.start_direct_session(media_file.id, viewer.id)

    on_exit(fn ->
      Mydia.Streaming.HlsSessionSupervisor.stop_direct_session(media_file.id, viewer.id)
    end)

    {:ok, view, _html} = live(authed(conn, token), ~p"/admin/dashboard")

    refute has_element?(view, "#now-playing-empty")
    assert has_element?(view, "#now-playing-#{media_file.id}")
    assert render(view) =~ "House of the Dragon"
  end

  test "the bandwidth KPI carries its unit", %{conn: conn, token: token} do
    {:ok, view, _html} = live(authed(conn, token), ~p"/admin/dashboard")

    assert view |> element("#kpi-bandwidth") |> render() =~ "Mbps"
  end
end
