defmodule MydiaWeb.ImportMediaInboxTest do
  @moduledoc """
  The review inbox is a live query, not session state: every assertion below
  either drives a real event through the mounted LiveView and re-reads the
  database, or exercises `Inbox.format_last_error/1` directly as a pure
  function. None of these compare against a hardcoded shell -- each one
  checks that a row's *content* is correct, or that it *changed* in response
  to an action, per the standing rule that `has_element?/2` alone proves
  nothing.
  """
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library
  alias MydiaWeb.ImportMediaLive.Inbox

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
        provider_type: "tmdb",
        provider_id: "603",
        title: "The Matrix",
        year: 1999,
        media_type: "movie",
        confidence: 0.95
      })

    {:ok, conn: log_in_user(conn, user), library_path: lp, media_file: media_file}
  end

  test "renders a row for the unresolved file, showing its match and file path", %{
    conn: conn,
    media_file: media_file
  } do
    {:ok, view, _html} = live(conn, ~p"/import")

    assert has_element?(view, "#import-inbox")
    assert has_element?(view, "#approve-#{media_file.id}")

    html = render(view)
    assert html =~ "The Matrix"
    assert html =~ media_file.relative_path
  end

  test "filtering to unidentified hides a matched file but keeps an unidentified one", %{
    conn: conn,
    media_file: media_file,
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

    {:ok, view, _html} = live(conn, ~p"/import")

    assert has_element?(view, "#approve-#{media_file.id}")
    assert has_element?(view, "#approve-#{unidentified.id}")

    view |> element("#inbox-filter") |> render_change(%{"filter" => "unidentified"})

    # Discriminates both ways: a broken filter that hid everything, or one
    # that filtered nothing, would each only fail one of these two.
    refute has_element?(view, "#approve-#{media_file.id}")
    assert has_element?(view, "#approve-#{unidentified.id}")
  end

  test "the inbox count tracks the current filter, not the total at mount", %{
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

    {:ok, view, _html} = live(conn, ~p"/import")

    assert render(view) =~ "2 files"

    view |> element("#inbox-filter") |> render_change(%{"filter" => "unidentified"})

    assert render(view) =~ "1 file"
    refute render(view) =~ "2 files"
  end

  describe "approving a match" do
    test "links the file to its match, clears its candidate, and removes it from the inbox", %{
      conn: conn,
      media_file: media_file
    } do
      # A MediaItem sharing the candidate's tmdb_id and updated within the
      # last hour is what lets MetadataEnricher take the "associate with an
      # existing item" branch (recently_enriched?/1) instead of fetching from
      # the relay -- the real production branch for a file matching a show or
      # movie already in the library, and one this test can exercise without
      # a live HTTP dependency.
      item = media_item_fixture(%{type: "movie", title: "The Matrix", year: 1999, tmdb_id: 603})

      {:ok, view, _html} = live(conn, ~p"/import")

      assert has_element?(view, "#approve-#{media_file.id}")

      html = view |> element("#approve-#{media_file.id}") |> render_click()

      assert html =~ "Added The Matrix"

      # The behavioural proof, not just the flash: an implementation that did
      # nothing but flash a success message would still pass a text-only
      # assertion, so this checks the actual database effects instead.
      refute has_element?(view, "#approve-#{media_file.id}")
      assert Library.get_media_file!(media_file.id).media_item_id == item.id
      assert Library.list_match_candidates(media_file.id) == []
    end

    test "refuses a file with no identified match yet and leaves it in the inbox", %{
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

      {:ok, view, _html} = live(conn, ~p"/import")

      # The row's own "Add" button really is `disabled` in the DOM --
      # Phoenix.LiveViewTest itself refuses to click a disabled element.
      assert_raise ArgumentError, ~r/disabled/, fn ->
        view |> element("#approve-#{unidentified.id}") |> render_click()
      end

      # Dispatching the event directly against the view, bypassing the DOM
      # element and its `disabled` attribute, is what proves the
      # *server-side* handler also refuses on its own, rather than the only
      # safety net being that the browser would never let this be clicked.
      html = render_click(view, "approve_file", %{"id" => unidentified.id})

      assert html =~ "no match to add"
      assert has_element?(view, "#approve-#{unidentified.id}")
      assert is_nil(Library.get_media_file!(unidentified.id).media_item_id)
    end
  end

  describe "a library type mismatch (Gap 2)" do
    test "renders distinctly from a genuine no-match, with the reason spelled out", %{
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

      {:ok, view, _html} = live(conn, ~p"/import")

      html = render(view)

      assert html =~ "Wrong library"
      assert html =~ "Cannot add movies to a library path configured for TV series only"
      refute html =~ "{:library_type_mismatch"
    end
  end

  describe "Inbox.format_last_error/1" do
    test "passes nil through unchanged" do
      assert Inbox.format_last_error(nil) == nil
    end

    test "turns the literal no_match string into a full sentence" do
      assert Inbox.format_last_error("no_match") =~ "No matching title"
    end

    test "unwraps an inspected library_type_mismatch tuple to its bare message" do
      raw =
        inspect(
          {:library_type_mismatch,
           "Cannot add TV shows to a library path configured for movies only (path: /media/movies)"}
        )

      assert Inbox.format_last_error(raw) ==
               "Cannot add TV shows to a library path configured for movies only (path: /media/movies)"
    end

    test "shows an unrecognised shape as-is rather than hiding it" do
      assert Inbox.format_last_error("something totally unexpected") ==
               "something totally unexpected"
    end
  end
end
