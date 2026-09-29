defmodule MydiaWeb.AdminDuplicatesMisfiledTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Accounts
  alias Mydia.Library.ImportCandidate
  alias Mydia.Repo

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

    %{conn: conn}
  end

  defp show_with_stray do
    show = media_item_fixture(%{type: "tv_show", title: "Harbor Lights", year: 2013})
    lp = library_path_fixture(%{type: "series"})
    e1 = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})
    e2 = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 2})

    good =
      media_file_fixture(%{
        episode_id: e1.id,
        library_path_id: lp.id,
        relative_path: "Harbor Lights/Season 01/Harbor.Lights.S01E01.1080p.mkv"
      })

    stray =
      media_file_fixture(%{
        episode_id: e2.id,
        library_path_id: lp.id,
        relative_path: "Vardo/Season 01/Vardo.S01E02.1080p.mkv"
      })

    {show, good, stray}
  end

  defp scan(view) do
    view |> element("#misfiled-scan") |> render_click()
    render_async(view)
  end

  test "shows nothing until scanned, then an empty state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/duplicates")

    refute has_element?(view, "#misfiled-empty")
    scan(view)
    assert has_element?(view, "#misfiled-empty")
  end

  test "lists a stray that collides with nothing, marked for Review", %{conn: conn} do
    {show, good, stray} = show_with_stray()
    {:ok, view, _html} = live(conn, ~p"/admin/duplicates")

    scan(view)

    assert has_element?(view, "#misfiled-item-#{show.id}")
    assert has_element?(view, "#misfiled-suspect-#{stray.id}")
    assert has_element?(view, "#misfiled-review-#{stray.id}[checked]")
    refute has_element?(view, "#misfiled-review-#{good.id}")
  end

  test "sending an item's marked files detaches them and drops the row", %{conn: conn} do
    {show, _good, stray} = show_with_stray()
    {:ok, view, _html} = live(conn, ~p"/admin/duplicates")
    scan(view)

    view |> element("#misfiled-send-item-#{show.id}") |> render_click()

    refute has_element?(view, "#misfiled-item-#{show.id}")

    assert %ImportCandidate{returned_at: %DateTime{}} =
             Repo.get_by(ImportCandidate, relative_path: stray.relative_path)
  end

  test "Leave takes a file out of the send", %{conn: conn} do
    {show, _good, stray} = show_with_stray()
    {:ok, view, _html} = live(conn, ~p"/admin/duplicates")
    scan(view)

    view |> element("#misfiled-leave-#{stray.id}") |> render_click()

    assert has_element?(view, "#misfiled-leave-#{stray.id}[checked]")
    assert has_element?(view, "#misfiled-send-item-#{show.id}[disabled]")
  end

  test "an item where nothing binds defaults to Leave and cannot be emptied", %{conn: conn} do
    movie = media_item_fixture(%{type: "movie", title: "Zephyr Station", year: 2030})
    lp = library_path_fixture(%{type: "movies"})

    only =
      media_file_fixture(%{
        media_item_id: movie.id,
        library_path_id: lp.id,
        relative_path: "Starveil (2031)/Starveil.2031.1080p.mkv"
      })

    {:ok, view, _html} = live(conn, ~p"/admin/duplicates")
    scan(view)

    assert has_element?(view, "#misfiled-leave-#{only.id}[checked]")
    assert has_element?(view, "#misfiled-review-#{only.id}[disabled]")
  end
end
