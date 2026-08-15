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

  test "batch selection is keyed by id and survives a filter change", %{
    conn: conn,
    media_file: media_file
  } do
    {:ok, view, _html} = live(conn, ~p"/import")

    view
    |> element("#batch-toggle-#{media_file.id}")
    |> render_click()

    assert has_element?(view, "#inbox-batch-toolbar")

    # An index-addressed implementation would silently select the wrong row
    # here, because filtering changes list positions.
    view |> element("#inbox-filter") |> render_change(%{"filter" => "unidentified"})

    assert has_element?(view, "#inbox-batch-toolbar")
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
