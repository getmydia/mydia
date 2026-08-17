defmodule MydiaWeb.ReviewMediaLiveTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.MetadataStub
  import Mydia.SettingsFixtures

  alias Mydia.Library

  # The batch and rematch search boxes call Metadata.search/3, which would
  # otherwise reach the live relay.
  setup :setup_metadata_stub

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

  test "approving a file links the media file, clears candidate, and removes it from the group",
       %{
         conn: conn,
         media_file: media_file
       } do
    item = media_item_fixture(%{type: "movie", title: "The Matrix", year: 1999, tmdb_id: 603})

    {:ok, view, _html} = live(conn, ~p"/review")

    assert has_element?(view, "#approve-#{media_file.id}")

    html = view |> element("#approve-#{media_file.id}") |> render_click()

    assert html =~ "Added The Matrix"
    refute has_element?(view, "#approve-#{media_file.id}")
    assert Library.get_media_file!(media_file.id).media_item_id == item.id
    assert Library.list_match_candidates(media_file.id) == []
  end

  test "approving a file another session already removed refreshes instead of crashing", %{
    conn: conn,
    media_file: media_file
  } do
    {:ok, view, _html} = live(conn, ~p"/review")

    {:ok, _} = Library.delete_media_file(media_file)

    html = view |> element("#approve-#{media_file.id}") |> render_click()

    assert html =~ "no longer in the queue"
    refute has_element?(view, "#approve-#{media_file.id}")
  end

  test "editing a file another session already removed refreshes instead of crashing", %{
    conn: conn,
    media_file: media_file
  } do
    {:ok, view, _html} = live(conn, ~p"/review")

    {:ok, _} = Library.delete_media_file(media_file)

    html = view |> element("#edit-#{media_file.id}") |> render_click()

    assert html =~ "no longer in the queue"
    refute has_element?(view, "#inbox-edit-form-#{media_file.id}")
  end

  test "the per-library badge is recomputed after a file is approved", %{
    conn: conn,
    library_path: library_path,
    media_file: media_file
  } do
    _item = media_item_fixture(%{type: "movie", title: "The Matrix", year: 1999, tmdb_id: 603})

    {:ok, view, _html} = live(conn, ~p"/review")

    assert view |> element("#review-library-#{library_path.id} .badge") |> render() =~ "1"

    view |> element("#approve-#{media_file.id}") |> render_click()

    assert view |> element("#review-library-#{library_path.id} .badge") |> render() =~ "0"
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

    view |> element("#season-select-111-s1") |> render_click()

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

    view |> element("#season-toggle-111-s1") |> render_click()
    refute has_element?(view, "#batch-toggle-#{f1.id}")

    view |> element("#season-toggle-111-s1") |> render_click()
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
    view |> element("#season-select-111-s1") |> render_click()
    assert has_element?(view, "#batch-toggle-#{f1.id}[checked]")
    assert has_element?(view, "#batch-toggle-#{f2.id}[checked]")

    # Toggle again should deselect all in season 1
    view |> element("#season-select-111-s1") |> render_click()
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

  test "re-matching a series re-points every episode and collapses the editor", %{
    conn: conn,
    library_path: lp
  } do
    f1 = orphaned_media_file_fixture(%{library_path_id: lp.id})

    {:ok, _} =
      Library.upsert_match_candidate(%{
        media_file_id: f1.id,
        rank: 0,
        provider_type: "tmdb",
        provider_id: "111",
        title: "Wrong Show",
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
        title: "Wrong Show",
        year: 2020,
        media_type: "tv_show",
        confidence: 0.9,
        parsed_info: %{"season" => 1, "episodes" => [2]}
      })

    {:ok, view, _html} = live(conn, ~p"/review")

    view |> element("#rematch-111") |> render_click()

    assert has_element?(view, "input[name=query]")

    view
    |> render_hook("select_series_rematch", %{
      "provider_id" => "1396",
      "title" => "Breaking Bad"
    })

    assert has_element?(view, "h3", "Breaking Bad")
    refute has_element?(view, "input[name=query]")
  end

  test "canceling series rematch collapses the editor", %{conn: conn, library_path: lp} do
    f1 = orphaned_media_file_fixture(%{library_path_id: lp.id})

    {:ok, _} =
      Library.upsert_match_candidate(%{
        media_file_id: f1.id,
        rank: 0,
        provider_type: "tmdb",
        provider_id: "111",
        title: "Wrong Show",
        year: 2020,
        media_type: "tv_show",
        confidence: 0.9,
        parsed_info: %{"season" => 1, "episodes" => [1]}
      })

    {:ok, view, _html} = live(conn, ~p"/review")

    view |> element("#rematch-111") |> render_click()
    assert has_element?(view, "input[name=query]")

    view |> render_hook("cancel_series_rematch", %{})
    refute has_element?(view, "input[name=query]")
  end

  test "readonly users cannot select series rematch", %{conn: conn, library_path: lp} do
    f1 = orphaned_media_file_fixture(%{library_path_id: lp.id})

    {:ok, _} =
      Library.upsert_match_candidate(%{
        media_file_id: f1.id,
        rank: 0,
        provider_type: "tmdb",
        provider_id: "111",
        title: "Wrong Show",
        year: 2020,
        media_type: "tv_show",
        confidence: 0.9,
        parsed_info: %{"season" => 1, "episodes" => [1]}
      })

    readonly_user = user_fixture(%{role: "readonly"})
    readonly_conn = log_in_user(conn, readonly_user)

    {:ok, view, _html} = live(readonly_conn, ~p"/review")

    view |> element("#rematch-111") |> render_click()

    view
    |> render_hook("select_series_rematch", %{
      "provider_id" => "1396",
      "title" => "Breaking Bad"
    })

    assert [candidate] = Library.list_match_candidates(f1.id)
    assert candidate.title == "Wrong Show"
  end

  test "searching series rematch with short query returns empty results", %{
    conn: conn,
    library_path: lp
  } do
    f1 = orphaned_media_file_fixture(%{library_path_id: lp.id})

    {:ok, _} =
      Library.upsert_match_candidate(%{
        media_file_id: f1.id,
        rank: 0,
        provider_type: "tmdb",
        provider_id: "111",
        title: "Wrong Show",
        year: 2020,
        media_type: "tv_show",
        confidence: 0.9,
        parsed_info: %{"season" => 1, "episodes" => [1]}
      })

    {:ok, view, _html} = live(conn, ~p"/review")

    view |> element("#rematch-111") |> render_click()

    view |> render_change("search_series_rematch", %{"query" => "a"})

    refute has_element?(view, "button[phx-click=select_series_rematch]")
  end

  test "refuses a file with no identified match yet", %{
    conn: conn,
    library_path: lp
  } do
    unidentified = orphaned_media_file_fixture(%{library_path_id: lp.id})

    {:ok, _} =
      Library.upsert_match_candidate(%{
        media_file_id: unidentified.id,
        rank: 0,
        attempts: 1,
        last_error: "no_match"
      })

    {:ok, view, _html} = live(conn, ~p"/review")

    assert_raise ArgumentError, ~r/disabled/, fn ->
      view |> element("#approve-#{unidentified.id}") |> render_click()
    end

    html = render_click(view, "approve_file", %{"id" => unidentified.id})

    assert html =~ "no match to add"
    assert is_nil(Library.get_media_file!(unidentified.id).media_item_id)
  end

  test "renders unmatched files section with per-file error text", %{
    conn: conn,
    library_path: lp
  } do
    unidentified = orphaned_media_file_fixture(%{library_path_id: lp.id})

    {:ok, _} =
      Library.upsert_match_candidate(%{
        media_file_id: unidentified.id,
        rank: 0,
        attempts: 1,
        last_error: "no_match"
      })

    {:ok, view, _html} = live(conn, ~p"/review")

    html = render(view)

    # The "No match" badge should be present
    assert html =~ "No match"
    # The per-file error reason should also be visible so users have
    # actionable information about why the file was not matched.
    assert html =~ "No matching title was found."
  end

  test "a candidate whose stored media type is unknown can still be added", %{
    conn: conn,
    library_path: lp
  } do
    file = orphaned_media_file_fixture(%{library_path_id: lp.id})

    {:ok, _} =
      Library.upsert_match_candidate(%{
        media_file_id: file.id,
        rank: 0,
        provider_type: "not_a_provider_7b2",
        provider_id: "603",
        title: "The Matrix",
        year: 1999,
        media_type: "not_a_media_type_7b2",
        confidence: 0.95
      })

    media_item_fixture(%{type: "movie", title: "The Matrix", year: 1999, tmdb_id: 603})

    {:ok, view, _html} = live(conn, ~p"/review")

    html = view |> element("#approve-#{file.id}") |> render_click()

    assert html =~ "Added The Matrix"
    assert Library.get_media_file!(file.id).media_item_id
  end

  test "an edit naming a media type the app has no clause for is stored as one it does", %{
    conn: conn,
    media_file: media_file
  } do
    {:ok, view, _html} = live(conn, ~p"/review")

    view |> element("#edit-#{media_file.id}") |> render_click()

    render_click(view, "select_search_result", %{
      "title" => "The Matrix",
      "provider_id" => "603",
      "type" => "not_a_media_type_7b2"
    })

    view |> form("#inbox-edit-form-#{media_file.id}") |> render_submit()

    assert [candidate] = Library.list_match_candidates(media_file.id)
    assert candidate.media_type == "movie"
  end

  test "renders library type mismatch in the wrong library section", %{
    conn: conn,
    library_path: lp
  } do
    mismatched = orphaned_media_file_fixture(%{library_path_id: lp.id})

    {:ok, _} =
      Library.upsert_match_candidate(%{
        media_file_id: mismatched.id,
        rank: 0,
        attempts: 1,
        last_error:
          inspect(
            {:library_type_mismatch,
             "Cannot add movies to a library path configured for TV series only (path: /media/tv)"}
          )
      })

    {:ok, view, _html} = live(conn, ~p"/review")

    html = render(view)

    assert html =~ "Wrong library"
    assert html =~ "These files were matched, but to a type this library cannot hold."
    refute html =~ "{:library_type_mismatch"
  end

  test "batch apply changes exactly the selected files, leaving unselected files untouched", %{
    conn: conn,
    library_path: lp
  } do
    file1 = orphaned_media_file_fixture(%{library_path_id: lp.id})

    {:ok, _} =
      Library.upsert_match_candidate(%{
        media_file_id: file1.id,
        rank: 0,
        attempts: 1,
        last_error: "no_match"
      })

    file2 = orphaned_media_file_fixture(%{library_path_id: lp.id})

    {:ok, _} =
      Library.upsert_match_candidate(%{
        media_file_id: file2.id,
        rank: 0,
        attempts: 1,
        last_error: "no_match"
      })

    file3 = orphaned_media_file_fixture(%{library_path_id: lp.id})

    {:ok, _} =
      Library.upsert_match_candidate(%{
        media_file_id: file3.id,
        rank: 0,
        attempts: 1,
        last_error: "no_match"
      })

    {:ok, view, _html} = live(conn, ~p"/review")

    view |> element("#batch-toggle-#{file1.id}") |> render_click()
    view |> element("#batch-toggle-#{file2.id}") |> render_click()

    render_click(view, "batch_select_search_result", %{
      "title" => "Selected Show",
      "provider_id" => "9001",
      "type" => "tv_show",
      "year" => "2020"
    })

    render_click(view, "batch_apply", %{})

    assert [c1] = Library.list_match_candidates(file1.id)
    assert c1.title == "Selected Show"
    assert c1.provider_id == "9001"
    assert c1.media_type == "tv_show"

    assert [c2] = Library.list_match_candidates(file2.id)
    assert c2.title == "Selected Show"
    assert c2.provider_id == "9001"

    assert [c3] = Library.list_match_candidates(file3.id)
    assert c3.title == nil
    assert c3.provider_id == nil
    assert c3.last_error == "no_match"
  end

  test "batch apply reports the files it could not update instead of claiming them all", %{
    conn: conn,
    library_path: lp
  } do
    kept = orphaned_media_file_fixture(%{library_path_id: lp.id})

    {:ok, _} =
      Library.upsert_match_candidate(%{
        media_file_id: kept.id,
        rank: 0,
        attempts: 1,
        last_error: "no_match"
      })

    vanishing = orphaned_media_file_fixture(%{library_path_id: lp.id})

    {:ok, _} =
      Library.upsert_match_candidate(%{
        media_file_id: vanishing.id,
        rank: 0,
        attempts: 1,
        last_error: "no_match"
      })

    {:ok, view, _html} = live(conn, ~p"/review")

    view |> element("#batch-toggle-#{kept.id}") |> render_click()
    view |> element("#batch-toggle-#{vanishing.id}") |> render_click()

    Mydia.Repo.delete!(Library.get_media_file!(vanishing.id))

    render_click(view, "batch_select_search_result", %{
      "title" => "Selected Show",
      "provider_id" => "9001",
      "type" => "tv_show",
      "year" => "2020"
    })

    html = render_click(view, "batch_apply", %{})

    assert html =~ "Batch edit applied to 1 file(s)"
    assert html =~ "1 could not be updated"

    assert [candidate] = Library.list_match_candidates(kept.id)
    assert candidate.title == "Selected Show"
    assert Library.list_match_candidates(vanishing.id) == []
  end
end
