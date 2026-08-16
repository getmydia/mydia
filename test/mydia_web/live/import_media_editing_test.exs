defmodule MydiaWeb.ImportMediaEditingTest do
  @moduledoc """
  Task 13: the inbox is addressed by `media_file_id`, not list position, so
  these tests exercise real events through the mounted LiveView and check
  database or rendered-content effects rather than just element presence --
  per the standing rule, `has_element?/2` alone proves nothing about *what*
  changed.

  The pagination test below is the one that actually proves the addressing
  claim: a single-row inbox can't distinguish "addressed by id" from
  "addressed by position" because the two coincide by accident. Putting the
  target file alone on page 2, at the same visual index-0 position a
  *different* file holds on page 1, is what makes the two implementations
  diverge.
  """
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library

  setup %{conn: conn} do
    # Roles are strings in this app: ~w(admin user readonly guest).
    user = user_fixture(%{role: "admin"})
    lp = library_path_fixture()

    # Named `media_file`, not `file` -- `:file` is a reserved ExUnit context
    # key (the test's own source file path) and setting it raises.
    media_file = orphaned_media_file_fixture(%{library_path_id: lp.id})

    {:ok, _} =
      Library.upsert_match_candidate(%{
        media_file_id: media_file.id,
        rank: 0,
        attempts: 1,
        last_error: "no_match"
      })

    {:ok, conn: log_in_user(conn, user), library_path: lp, media_file: media_file}
  end

  test "opens the editor for a file by id", %{conn: conn, media_file: media_file} do
    {:ok, view, _html} = live(conn, ~p"/import")

    view |> element("#edit-#{media_file.id}") |> render_click()

    assert has_element?(view, "#inbox-edit-form-#{media_file.id}")
  end

  test "saving an edit writes a candidate the file can be added from", %{
    conn: conn,
    media_file: media_file
  } do
    {:ok, view, _html} = live(conn, ~p"/import")

    view |> element("#edit-#{media_file.id}") |> render_click()

    # `provider_id` and `type` are hidden fields in the real form -- a user
    # sets them by picking a search result, not by typing into them.
    # Phoenix.LiveViewTest.form/3 enforces exactly that: it refuses a
    # submitted value for a hidden input that does not match what is
    # actually rendered, so the test has to go through select_search_result
    # the same way a click on the dropdown would.
    render_click(view, "select_search_result", %{
      "title" => "The Matrix",
      "provider_id" => "603",
      "type" => "movie"
    })

    view |> form("#inbox-edit-form-#{media_file.id}") |> render_submit()

    assert [candidate] = Library.list_match_candidates(media_file.id)
    assert candidate.title == "The Matrix"
    assert candidate.provider_id == "603"
  end

  test "saving an edit for a TV episode stores the season and episode list", %{
    conn: conn,
    media_file: media_file
  } do
    {:ok, view, _html} = live(conn, ~p"/import")

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
    assert candidate.media_type == "tv_show"
    assert candidate.parsed_info["season"] == 2
    assert candidate.parsed_info["episodes"] == [3, 4]
  end

  test "cancelling an edit closes the form without writing a candidate change", %{
    conn: conn,
    media_file: media_file
  } do
    {:ok, view, _html} = live(conn, ~p"/import")

    view |> element("#edit-#{media_file.id}") |> render_click()
    assert has_element?(view, "#inbox-edit-form-#{media_file.id}")

    view
    |> element("#inbox-edit-form-#{media_file.id} [phx-click='cancel_edit']")
    |> render_click()

    refute has_element?(view, "#inbox-edit-form-#{media_file.id}")
    assert [candidate] = Library.list_match_candidates(media_file.id)
    assert candidate.last_error == "no_match"
  end

  test "batch selection tracks the specific file id, not the position a filter change frees up",
       %{conn: conn, library_path: lp} do
    # Alpha and Bravo are identified, so the "unidentified" filter drops them
    # entirely. Under "all" they sort by title: Alpha at position 0, Bravo at
    # position 1.
    alpha =
      orphaned_media_file_fixture(%{library_path_id: lp.id, relative_path: "batch/alpha.mkv"})

    {:ok, _} =
      Library.upsert_match_candidate(%{
        media_file_id: alpha.id,
        rank: 0,
        provider_type: "tmdb",
        provider_id: "501",
        title: "Alpha Movie",
        media_type: "movie",
        confidence: 0.9
      })

    bravo =
      orphaned_media_file_fixture(%{library_path_id: lp.id, relative_path: "batch/bravo.mkv"})

    {:ok, _} =
      Library.upsert_match_candidate(%{
        media_file_id: bravo.id,
        rank: 0,
        provider_type: "tmdb",
        provider_id: "502",
        title: "Bravo Movie",
        media_type: "movie",
        confidence: 0.9
      })

    # Charlie and Delta are unidentified, so they alone survive the
    # "unidentified" filter. Both have a nil title, so relative_path breaks
    # the tie: Charlie lands at position 0 there, Delta at position 1 --
    # Delta is the one that inherits Bravo's old position.
    charlie =
      orphaned_media_file_fixture(%{library_path_id: lp.id, relative_path: "batch/charlie.mkv"})

    {:ok, _} =
      Library.upsert_match_candidate(%{
        media_file_id: charlie.id,
        rank: 0,
        attempts: 1,
        last_error: "no_match"
      })

    delta =
      orphaned_media_file_fixture(%{library_path_id: lp.id, relative_path: "batch/delta.mkv"})

    {:ok, _} =
      Library.upsert_match_candidate(%{
        media_file_id: delta.id,
        rank: 0,
        attempts: 1,
        last_error: "no_match"
      })

    {:ok, view, _html} = live(conn, ~p"/import")

    # Toggle Bravo -- position 1 under "all", not the first row, so a bug
    # that only ever checks position 0 could not pass this by accident.
    view |> element("#batch-toggle-#{bravo.id}") |> render_click()

    assert has_element?(view, "#inbox-batch-toolbar")
    assert has_element?(view, "#batch-toggle-#{bravo.id}[checked]")

    # Switching to "unidentified" drops Alpha and Bravo from the rendered
    # list entirely, and Delta -- a file nobody selected -- now sits at
    # position 1, the position Bravo held a moment ago. A position-addressed
    # implementation (a MapSet of row indices instead of ids) would render
    # Delta as checked here; an id-addressed one cannot, because Delta's id
    # was never put in the selected set.
    view |> element("#inbox-filter") |> render_change(%{"filter" => "unidentified"})

    assert has_element?(view, "#inbox-batch-toolbar")
    refute has_element?(view, "#batch-toggle-#{delta.id}[checked]")
    refute has_element?(view, "#batch-toggle-#{charlie.id}[checked]")

    # And switching back confirms the original selection -- Bravo, and only
    # Bravo -- survived the round trip untouched.
    view |> element("#inbox-filter") |> render_change(%{"filter" => "all"})

    assert has_element?(view, "#batch-toggle-#{bravo.id}[checked]")
    refute has_element?(view, "#batch-toggle-#{alpha.id}[checked]")
  end

  test "batch apply changes exactly the selected files, leaving the rest untouched", %{
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

    {:ok, view, _html} = live(conn, ~p"/import")

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

    # The load-bearing assertion: file3 was never selected, so a batch bug
    # that operates over the wrong set (e.g. "everything on the page", or a
    # miscomputed id list) would show up here even if file1 and file2 above
    # happened to look correct.
    assert [c3] = Library.list_match_candidates(file3.id)
    assert c3.title == nil
    assert c3.provider_id == nil
    assert c3.last_error == "no_match"
  end

  test "an edit naming a media type the app has no clause for is stored as one it does", %{
    conn: conn,
    media_file: media_file
  } do
    {:ok, view, _html} = live(conn, ~p"/import")

    view |> element("#edit-#{media_file.id}") |> render_click()

    # `type` rides a hidden field, so its value is whatever the client sends.
    # It is written straight to a column with no enum behind it and read back
    # as an atom when the file is approved, which is where an unknown value
    # used to surface -- as a crash, one screen away from where it entered.
    render_click(view, "select_search_result", %{
      "title" => "The Matrix",
      "provider_id" => "603",
      "type" => "not_a_media_type_7b2"
    })

    view |> form("#inbox-edit-form-#{media_file.id}") |> render_submit()

    assert [candidate] = Library.list_match_candidates(media_file.id)
    assert candidate.media_type == "movie"
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

    {:ok, view, _html} = live(conn, ~p"/import")

    view |> element("#batch-toggle-#{kept.id}") |> render_click()
    view |> element("#batch-toggle-#{vanishing.id}") |> render_click()

    # The file goes away between this page rendering and the button being
    # pressed: a scan that noticed it was gone, or a delete from another tab.
    # Its candidate goes with it, on delete cascade.
    Mydia.Repo.delete!(Library.get_media_file!(vanishing.id))

    render_click(view, "batch_select_search_result", %{
      "title" => "Selected Show",
      "provider_id" => "9001",
      "type" => "tv_show",
      "year" => "2020"
    })

    html = render_click(view, "batch_apply", %{})

    # The flash used to report every selected file as edited no matter what
    # came back from the write, so a rejected changeset looked exactly like a
    # success from the only place a user can see.
    assert html =~ "Batch edit applied to 1 file(s)"
    assert html =~ "1 could not be updated"

    assert [candidate] = Library.list_match_candidates(kept.id)
    assert candidate.title == "Selected Show"
    assert Library.list_match_candidates(vanishing.id) == []
  end

  describe "addressing survives pagination" do
    test "editing the sole row on page 2 opens its own editor, not the row that occupies the same position on page 1",
         %{conn: conn, library_path: lp, media_file: media_file} do
      # Retitle the setup fixture so it has content distinct from the movie
      # rows below, and sorts after every one of them ("Z" > "M") -- landing
      # it alone on page 2, at the exact index-0 position "Movie 001" holds
      # on page 1.
      {:ok, _} =
        Library.upsert_match_candidate(%{
          media_file_id: media_file.id,
          rank: 0,
          provider_type: "tmdb",
          provider_id: "77777",
          title: "Z2 Mystery Film",
          media_type: "movie",
          confidence: 0.9
        })

      # A second row that also lands on page 2, sorting immediately before
      # `media_file` -- so page 2 has two rows and the target is NOT the
      # first one there. This is what rules out a broken implementation that
      # resolves "whichever row is first on the current page" instead of the
      # row whose id was actually clicked: with only one row on page 2 (as an
      # earlier draft of this test had it), such a bug would coincidentally
      # still resolve to the right file.
      other_page_two_file = orphaned_media_file_fixture(%{library_path_id: lp.id})

      {:ok, _} =
        Library.upsert_match_candidate(%{
          media_file_id: other_page_two_file.id,
          rank: 0,
          provider_type: "tmdb",
          provider_id: "88888",
          title: "Z1 Another File",
          media_type: "movie",
          confidence: 0.9
        })

      # index.ex's @inbox_page_size is 100. 100 "Movie NNN" rows fill page 1
      # completely; the two "Z"-titled rows above sort after all of them and
      # land together on page 2.
      create_movie_rows(lp, 100)

      {:ok, view, _html} = live(conn, ~p"/import")

      view |> element("#inbox-next-page") |> render_click()

      # Both land on page 2, "Z1 Another File" first.
      assert has_element?(view, "#edit-#{other_page_two_file.id}")
      assert has_element?(view, "#edit-#{media_file.id}")

      view |> element("#edit-#{media_file.id}") |> render_click()

      # Content, not just presence, and scoped to the editor itself: "Z1
      # Another File" legitimately still appears elsewhere on the page (its
      # own row in the list), so the assertion has to look specifically at
      # what the editor populated, not the page as a whole. A broken
      # implementation that resolved "the first row on the current page"
      # instead of "the row whose id was clicked" would populate the editor
      # with "Z1 Another File"'s data, since that is the row sitting at
      # position 0 on this page.
      assert has_element?(
               view,
               "#inbox-edit-form-#{media_file.id} input[value='Z2 Mystery Film']"
             )

      refute has_element?(
               view,
               "#inbox-edit-form-#{media_file.id} input[value='Z1 Another File']"
             )
    end
  end

  # Creates `count` distinct, confidently-matched inbox rows in
  # `library_path`, titled "Movie 001".."Movie <count>" (zero-padded to 3
  # digits so string sort order matches numeric order) -- the same fixture
  # shape import_media_inbox_test.exs uses for its pagination tests.
  defp create_movie_rows(library_path, count) do
    for n <- 1..count do
      media_file = orphaned_media_file_fixture(%{library_path_id: library_path.id})

      {:ok, _} =
        Library.upsert_match_candidate(%{
          media_file_id: media_file.id,
          rank: 0,
          provider_type: "tmdb",
          provider_id: "#{10_000 + n}",
          title: "Movie #{String.pad_leading(Integer.to_string(n), 3, "0")}",
          media_type: "movie",
          confidence: 0.9
        })

      media_file
    end
  end
end
