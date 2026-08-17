defmodule MydiaWeb.ReviewMediaLiveTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library

  setup %{conn: conn} do
    user = user_fixture(%{role: "admin"})
    lp = library_path_fixture()

    media_file = orphaned_media_file_fixture(%{library_path_id: lp.id})

    {:ok, _} =
      Library.upsert_match_candidate(%{
        media_file_id: media_file.id,
        rank: 0,
        provider_type: "tmdb",
        provider_id: "603",
        title: "The Matrix",
        year: 1999,
        media_type: "movie",
        confidence: 0.95
      })

    {:ok, conn: log_in_user(conn, user), library_path: lp, media_file: media_file}
  end

  test "approving a file removes it from the group", %{conn: conn, media_file: media_file} do
    {:ok, view, _html} = live(conn, ~p"/review")

    assert has_element?(view, "#approve-#{media_file.id}")

    view |> element("#approve-#{media_file.id}") |> render_click()

    refute has_element?(view, "#approve-#{media_file.id}")
  end

  test "opening the editor renders the edit form", %{conn: conn, media_file: media_file} do
    {:ok, view, _html} = live(conn, ~p"/review")

    view |> element("#edit-#{media_file.id}") |> render_click()

    assert has_element?(view, "#inbox-edit-form-#{media_file.id}")
  end

  test "canceling edit closes the editor", %{conn: conn, media_file: media_file} do
    {:ok, view, _html} = live(conn, ~p"/review")

    view |> element("#edit-#{media_file.id}") |> render_click()
    assert has_element?(view, "#inbox-edit-form-#{media_file.id}")

    view |> element("#inbox-edit-form-#{media_file.id} button", "Cancel") |> render_click()
    refute has_element?(view, "#inbox-edit-form-#{media_file.id}")
  end

  test "saving an edit updates match candidate and closes editor", %{
    conn: conn,
    media_file: media_file
  } do
    {:ok, view, _html} = live(conn, ~p"/review")

    view |> element("#edit-#{media_file.id}") |> render_click()

    render_click(view, "select_search_result", %{
      "title" => "The Matrix Reloaded",
      "provider_id" => "604",
      "type" => "movie"
    })

    view |> form("#inbox-edit-form-#{media_file.id}") |> render_submit()

    assert [candidate] = Library.list_match_candidates(media_file.id)
    assert candidate.title == "The Matrix Reloaded"
    assert candidate.provider_id == "604"
    refute has_element?(view, "#inbox-edit-form-#{media_file.id}")
  end

  test "saving an edit for a TV episode stores season and episodes", %{
    conn: conn,
    media_file: media_file
  } do
    {:ok, view, _html} = live(conn, ~p"/review")

    view |> element("#edit-#{media_file.id}") |> render_click()

    render_click(view, "select_search_result", %{
      "title" => "Breaking Bad",
      "provider_id" => "1396",
      "type" => "tv_show"
    })

    view
    |> form("#inbox-edit-form-#{media_file.id}", %{
      "edit_form" => %{"season" => "2", "episodes" => "3, 4"}
    })
    |> render_submit()

    assert [candidate] = Library.list_match_candidates(media_file.id)
    assert candidate.title == "Breaking Bad"
    assert candidate.parsed_info["season"] == 2
    assert candidate.parsed_info["episodes"] == [3, 4]
  end

  test "readonly users cannot approve files", %{conn: conn, media_file: media_file} do
    readonly_user = user_fixture(%{role: "readonly"})
    readonly_conn = log_in_user(conn, readonly_user)

    {:ok, view, _html} = live(readonly_conn, ~p"/review")

    assert has_element?(view, "#approve-#{media_file.id}")

    view |> element("#approve-#{media_file.id}") |> render_click()

    # The file should still be there because readonly user is unauthorized
    assert has_element?(view, "#approve-#{media_file.id}")
  end

  test "readonly users cannot save edits", %{conn: conn, media_file: media_file} do
    readonly_user = user_fixture(%{role: "readonly"})
    readonly_conn = log_in_user(conn, readonly_user)

    {:ok, view, _html} = live(readonly_conn, ~p"/review")

    view |> element("#edit-#{media_file.id}") |> render_click()

    render_click(view, "select_search_result", %{
      "title" => "The Matrix Reloaded",
      "provider_id" => "604",
      "type" => "movie"
    })

    view |> form("#inbox-edit-form-#{media_file.id}") |> render_submit()

    # Candidate should remain unchanged
    assert [candidate] = Library.list_match_candidates(media_file.id)
    assert candidate.title == "The Matrix"
    assert candidate.provider_id == "603"
  end
end
