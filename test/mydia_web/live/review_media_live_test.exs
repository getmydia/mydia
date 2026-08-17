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

  test "toggling a season checkbox selects every episode in that season", %{conn: conn} do
    lp = library_path_fixture()

    f1 = orphaned_media_file_fixture(%{library_path_id: lp.id})

    {:ok, _} =
      Library.upsert_match_candidate(%{
        media_file_id: f1.id,
        rank: 0,
        provider_type: "tmdb",
        provider_id: "111",
        title: "Show A",
        year: 2020,
        media_type: "tv_show",
        confidence: 0.9,
        parsed_info: %{"season" => 1, "episodes" => [1]}
      })

    f2 = orphaned_media_file_fixture(%{library_path_id: lp.id})

    {:ok, _} =
      Library.upsert_match_candidate(%{
        media_file_id: f2.id,
        rank: 0,
        provider_type: "tmdb",
        provider_id: "111",
        title: "Show A",
        year: 2020,
        media_type: "tv_show",
        confidence: 0.9,
        parsed_info: %{"season" => 2, "episodes" => [1]}
      })

    {:ok, view, _html} = live(conn, ~p"/review")

    view |> element("#season-select-#{f1.id}") |> render_click()

    assert has_element?(view, "#batch-toggle-#{f1.id}[checked]")
    refute has_element?(view, "#batch-toggle-#{f2.id}[checked]")
  end

  test "collapsing a season hides its episodes and expanding shows them", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})

    f1 = orphaned_media_file_fixture(%{library_path_id: lp.id})

    {:ok, _} =
      Library.upsert_match_candidate(%{
        media_file_id: f1.id,
        rank: 0,
        provider_type: "tmdb",
        provider_id: "111",
        title: "Show A",
        year: 2020,
        media_type: "tv_show",
        confidence: 0.9,
        parsed_info: %{"season" => 1, "episodes" => [1]}
      })

    {:ok, view, _html} = live(conn, ~p"/review")

    view |> element("#review-library-#{lp.id}") |> render_click()

    assert has_element?(view, "#batch-toggle-#{f1.id}")

    view |> element("#season-toggle-#{f1.id}") |> render_click()
    refute has_element?(view, "#batch-toggle-#{f1.id}")

    view |> element("#season-toggle-#{f1.id}") |> render_click()
    assert has_element?(view, "#batch-toggle-#{f1.id}")
  end

  test "batch toggling and batch actions workflow", %{conn: conn, media_file: media_file} do
    {:ok, view, _html} = live(conn, ~p"/review")

    refute has_element?(view, "#inbox-batch-toolbar")

    # Toggle file
    view |> element("#batch-toggle-#{media_file.id}") |> render_click()
    assert has_element?(view, "#inbox-batch-toolbar")
    assert has_element?(view, "#batch-toggle-#{media_file.id}[checked]")

    # Deselect all
    view |> render_click("batch_deselect_all")
    refute has_element?(view, "#inbox-batch-toolbar")

    # Select all
    view |> render_click("batch_select_all")
    assert has_element?(view, "#inbox-batch-toolbar")

    # Search and select search result
    view |> render_keyup("batch_search", %{"value" => "Breaking Bad"})

    view
    |> render_click("batch_select_search_result", %{
      "title" => "Breaking Bad",
      "provider_id" => "1396",
      "type" => "tv_show",
      "year" => "2008"
    })

    # Update season
    view |> render_keyup("batch_update_season", %{"value" => "3"})

    # Apply batch
    view |> render_click("batch_apply")

    assert [candidate] = Library.list_match_candidates(media_file.id)
    assert candidate.title == "Breaking Bad"
    assert candidate.provider_id == "1396"
    assert candidate.parsed_info["season"] == 3
    refute has_element?(view, "#inbox-batch-toolbar")
  end

  test "batch apply with empty params sets flash error", %{conn: conn, media_file: media_file} do
    {:ok, view, _html} = live(conn, ~p"/review")

    view |> element("#batch-toggle-#{media_file.id}") |> render_click()
    view |> render_click("batch_apply")

    assert render(view) =~ "No changes to apply"
  end

  test "readonly users cannot batch apply", %{conn: conn, media_file: media_file} do
    readonly_user = user_fixture(%{role: "readonly"})
    readonly_conn = log_in_user(conn, readonly_user)

    {:ok, view, _html} = live(readonly_conn, ~p"/review")

    view |> element("#batch-toggle-#{media_file.id}") |> render_click()

    view
    |> render_click("batch_select_search_result", %{
      "title" => "Breaking Bad",
      "provider_id" => "1396",
      "type" => "tv_show"
    })

    view |> render_click("batch_apply")

    # Candidate should remain unchanged
    assert [candidate] = Library.list_match_candidates(media_file.id)
    assert candidate.title == "The Matrix"
  end

  test "toggling season checkbox when all episodes are selected deselects them", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})

    f1 = orphaned_media_file_fixture(%{library_path_id: lp.id})

    {:ok, _} =
      Library.upsert_match_candidate(%{
        media_file_id: f1.id,
        rank: 0,
        provider_type: "tmdb",
        provider_id: "111",
        title: "Show A",
        year: 2020,
        media_type: "tv_show",
        confidence: 0.9,
        parsed_info: %{"season" => 1, "episodes" => [1]}
      })

    f2 = orphaned_media_file_fixture(%{library_path_id: lp.id})

    {:ok, _} =
      Library.upsert_match_candidate(%{
        media_file_id: f2.id,
        rank: 0,
        provider_type: "tmdb",
        provider_id: "111",
        title: "Show A",
        year: 2020,
        media_type: "tv_show",
        confidence: 0.9,
        parsed_info: %{"season" => 1, "episodes" => [2]}
      })

    {:ok, view, _html} = live(conn, ~p"/review")
    view |> element("#review-library-#{lp.id}") |> render_click()

    # Select all in season 1
    view |> element("#season-select-#{f1.id}") |> render_click()
    assert has_element?(view, "#batch-toggle-#{f1.id}[checked]")
    assert has_element?(view, "#batch-toggle-#{f2.id}[checked]")

    # Toggle again should deselect all in season 1
    view |> element("#season-select-#{f1.id}") |> render_click()
    refute has_element?(view, "#batch-toggle-#{f1.id}[checked]")
    refute has_element?(view, "#batch-toggle-#{f2.id}[checked]")
  end

  test "clearing batch match resets selected match", %{conn: conn, media_file: media_file} do
    {:ok, view, _html} = live(conn, ~p"/review")

    view |> element("#batch-toggle-#{media_file.id}") |> render_click()

    view
    |> render_click("batch_select_search_result", %{
      "title" => "Breaking Bad",
      "provider_id" => "1396",
      "type" => "tv_show"
    })

    assert render(view) =~ "Breaking Bad"

    view |> render_click("batch_clear_match")
    refute render(view) =~ "Breaking Bad"
  end

  test "batch toggling an id not in group does nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/review")

    fake_id = "00000000-0000-0000-0000-000000000000"
    view |> render_click("batch_toggle_file", %{"id" => fake_id})

    refute has_element?(view, "#inbox-batch-toolbar")
  end
end
