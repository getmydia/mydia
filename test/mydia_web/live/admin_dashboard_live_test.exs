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

  test "renders the KPI row for an admin", %{conn: conn, token: token} do
    {:ok, view, _html} = live(authed(conn, token), ~p"/admin/dashboard")

    assert has_element?(view, "#kpi-active-streams")
    assert has_element?(view, "#kpi-plays-today")
    assert has_element?(view, "#kpi-plays-week")
    refute has_element?(view, "#kpi-bandwidth")
  end

  test "renders empty states on an idle server", %{conn: conn, token: token} do
    {:ok, view, _html} = live(authed(conn, token), ~p"/admin/dashboard")

    assert has_element?(view, "#now-playing-empty")
    refute has_element?(view, "#bandwidth-chart")
    refute has_element?(view, "#bandwidth-chart-empty")
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
end
