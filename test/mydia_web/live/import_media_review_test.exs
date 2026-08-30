defmodule MydiaWeb.ImportMediaReviewTest do
  use MydiaWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.MetadataStub
  import Mydia.SettingsFixtures

  alias Mydia.ImportCandidates
  alias Mydia.Library.{ImportCandidate, ImportCandidateGroup}
  alias Mydia.MetadataStubProvider
  alias Mydia.Repo

  setup :setup_metadata_stub

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  # Seeds `count` (default 1) durable candidates under one anchor folder. Every
  # attr in `attrs` is applied to every candidate in the anchor, matching how a
  # real batch match writes the same verdict across a whole folder.
  defp seed_group(lp, anchor_key, attrs \\ %{}) do
    attrs = Map.new(attrs)
    count = Map.get(attrs, :file_count, 1)
    attrs = Map.delete(attrs, :file_count)

    # Defaults to a single-provider, fully-confident (`:ready`) group unless
    # overridden -- a caller building a `:no_match` group passes
    # `provider_id: nil, confidence: nil` explicitly.
    defaults = %{provider_id: "1", provider_type: "tvdb", confidence: 1.0}

    for n <- 1..count do
      import_candidate_fixture(
        Map.merge(
          %{
            library_path_id: lp.id,
            anchor_key: anchor_key,
            relative_path: "#{anchor_key}/file-#{n}.mkv"
          },
          Map.merge(defaults, attrs)
        )
      )
    end
  end

  defp fetch_group(lp, anchor_key, opts \\ []) do
    ImportCandidates.get_group(lp.id, anchor_key, opts)
  end

  # A minimal group struct built straight from a candidate's own identity,
  # without a query -- valid for computing `ImportCandidateGroup.dom_id/1`
  # regardless of whether the anchor is still pending, already dismissed, or
  # gone entirely, which is exactly what the dismiss-durability regression
  # below needs to check for absence.
  defp group_for(%ImportCandidate{} = candidate) do
    %ImportCandidateGroup{
      id: candidate.anchor_key,
      anchor_key: candidate.anchor_key,
      library_path_id: candidate.library_path_id,
      file_count: 1
    }
  end

  # Simulates a rescan's discovery phase rediscovering every already-known
  # path (dismissed or not) for a library -- the same upsert
  # `Jobs.ImportRun.run_scan_phase/2` performs for a file it has already seen.
  defp rerun_import(lp) do
    ImportCandidate
    |> where([c], c.library_path_id == ^lp.id)
    |> Repo.all()
    |> Enum.each(fn candidate ->
      ImportCandidates.upsert(
        candidate
        |> Map.from_struct()
        |> Map.take([:library_path_id, :relative_path, :anchor_key, :size, :discovered_at])
      )
    end)
  end

  # Extracts the ids of every rendered group row from the `#groups` stream
  # container, in DOM order. Used by the paging test to compare pages without
  # asserting on raw HTML.
  defp rendered_group_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#groups > div")
    |> LazyHTML.attribute("id")
    |> Enum.reject(&(&1 == "no-groups"))
  end

  test "dismissed work stays hidden after clear and a new import run", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})
    candidate = import_candidate_fixture(%{library_path_id: lp.id})
    {:ok, view, _html} = live(conn, ~p"/import?library_path_id=#{lp.id}")

    render_click(view, "toggle_group", %{"id" => candidate.anchor_key})
    view |> element("#dismiss-selected") |> render_click()
    view |> element("#clear-scan-results") |> render_click()
    rerun_import(lp)

    refute has_element?(view, "#group-#{ImportCandidateGroup.dom_id(group_for(candidate))}")
    assert Repo.reload!(candidate).dismissed_at
  end

  test "renders one row per group, not one row per member file", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})
    seed_group(lp, "cornemuse", %{file_count: 3})
    seed_group(lp, "pin-pon", %{file_count: 3})

    a = fetch_group(lp, "cornemuse")
    b = fetch_group(lp, "pin-pon")

    {:ok, view, _html} = live(conn, ~p"/import")

    assert has_element?(view, "#group-#{ImportCandidateGroup.dom_id(a)}")
    assert has_element?(view, "#group-#{ImportCandidateGroup.dom_id(b)}")
  end

  test "shows band counts", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})
    seed_group(lp, "a", %{confidence: 1.0})
    seed_group(lp, "b", %{confidence: 0.7})
    seed_group(lp, "c", %{provider_id: nil, confidence: nil})

    {:ok, view, _html} = live(conn, ~p"/import")

    assert has_element?(view, "#band-ready", "1")
    assert has_element?(view, "#band-needs-attention", "1")
    assert has_element?(view, "#band-no-match", "1")
  end

  test "shows a conflicting-matches badge when candidates in a group disagree on provider",
       %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})

    import_candidate_fixture(%{
      library_path_id: lp.id,
      anchor_key: "disagreement",
      relative_path: "disagreement/a.mkv",
      provider_id: "1",
      confidence: 1.0
    })

    import_candidate_fixture(%{
      library_path_id: lp.id,
      anchor_key: "disagreement",
      relative_path: "disagreement/b.mkv",
      provider_id: "2",
      confidence: 1.0
    })

    group = fetch_group(lp, "disagreement")
    {:ok, view, _html} = live(conn, ~p"/import")

    assert has_element?(
             view,
             "#group-#{ImportCandidateGroup.dom_id(group)}",
             "2 conflicting matches"
           )
  end

  test "the create-local-show button only appears on a no-match group's row", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})
    seed_group(lp, "matched", %{provider_id: "1", provider_type: "tvdb", confidence: 1.0})
    seed_group(lp, "no-match", %{provider_id: nil, confidence: nil})

    matched = fetch_group(lp, "matched")
    no_match = fetch_group(lp, "no-match")

    {:ok, view, _html} = live(conn, ~p"/import")

    refute has_element?(view, "#create-local-#{ImportCandidateGroup.dom_id(matched)}")
    assert has_element?(view, "#create-local-#{ImportCandidateGroup.dom_id(no_match)}")
  end

  test "creating a local show from a no-match group's folder links its files and clears it from the queue",
       %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})

    candidate =
      import_candidate_fixture(%{
        library_path_id: lp.id,
        anchor_key: "les mots de passe partout",
        relative_path: "Les mots de Passe-Partout (2023)/Season 01/ep1.mkv",
        media_type: "tv_show",
        parsed_info: %{"season" => 1, "episodes" => [1]}
      })

    group = fetch_group(lp, "les mots de passe partout")
    {:ok, view, _html} = live(conn, ~p"/import")

    view |> element("#create-local-#{ImportCandidateGroup.dom_id(group)}") |> render_click()

    assert has_element?(view, "#flash-info", "Les Mots De Passe Partout")
    refute has_element?(view, "#group-#{ImportCandidateGroup.dom_id(group)}")

    refute Repo.get(ImportCandidate, candidate.id)
    assert Repo.aggregate(Mydia.Media.MediaItem, :count) == 1
  end

  test "creating a local show reports leftover unnumbered files rather than a clean success",
       %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})

    import_candidate_fixture(%{
      library_path_id: lp.id,
      anchor_key: "l'univers des coucou",
      relative_path: "L'univers des Coucou (2023)/Season 01/ep1.mkv",
      media_type: "tv_show",
      parsed_info: %{"season" => 1, "episodes" => [1]}
    })

    unnumbered =
      import_candidate_fixture(%{
        library_path_id: lp.id,
        anchor_key: "l'univers des coucou",
        relative_path: "L'univers des Coucou (2023)/Season 01/bonus.mkv",
        media_type: "tv_show",
        parsed_info: %{}
      })

    group = fetch_group(lp, "l'univers des coucou")
    {:ok, view, _html} = live(conn, ~p"/import")

    view |> element("#create-local-#{ImportCandidateGroup.dom_id(group)}") |> render_click()

    assert has_element?(view, "#flash-info", "linked 1 of 2 files")
    assert has_element?(view, "#flash-info", "1 had no episode number")

    # A partially-linked anchor stays visible (see ImportCandidates.create_local_show/2):
    # the leftover, unnumbered candidate is stamped provider_type "local" and
    # keeps the anchor alive, but it no longer offers Create-show-from-folder
    # since it is no longer :no_match (it now carries a provider identity).
    reloaded_group = fetch_group(lp, "l'univers des coucou")
    assert reloaded_group
    assert has_element?(view, "#group-#{ImportCandidateGroup.dom_id(reloaded_group)}")
    refute has_element?(view, "#create-local-#{ImportCandidateGroup.dom_id(reloaded_group)}")

    assert Repo.reload!(unnumbered).provider_type == "local"
  end

  test "a second click on create-local-show is refused instead of creating a duplicate show",
       %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})

    import_candidate_fixture(%{
      library_path_id: lp.id,
      anchor_key: "les mots de passe partout",
      relative_path: "Les mots de Passe-Partout (2023)/Season 01/bonus.mkv",
      media_type: "tv_show",
      parsed_info: %{}
    })

    {:ok, view, _html} = live(conn, ~p"/import")

    render_click(view, "create_local_show", %{"id" => "les mots de passe partout"})
    assert has_element?(view, "#flash-info", "Les Mots De Passe Partout")

    # No `phx-disable-with` guards the button, so the anchor key is still a
    # valid target for a stale or replayed event even after the leftover
    # candidate has been stamped local-marked and the row has re-rendered.
    render_click(view, "create_local_show", %{"id" => "les mots de passe partout"})

    assert has_element?(view, "#flash-info", "already created")
    assert Repo.aggregate(Mydia.Media.MediaItem, :count) == 1
  end

  test "a ready group renders collapsed and expands on click", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})
    [candidate] = seed_group(lp, "show", %{confidence: 1.0})
    group = fetch_group(lp, "show")

    {:ok, view, _html} = live(conn, ~p"/import")

    refute has_element?(view, "#member-#{candidate.id}")

    view
    |> element("#group-toggle-#{ImportCandidateGroup.dom_id(group)}")
    |> render_click()

    assert has_element?(view, "#member-#{candidate.id}")
  end

  test "expanding another group collapses the previously expanded group", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})
    [candidate_a] = seed_group(lp, "show a", %{confidence: 1.0})
    [candidate_b] = seed_group(lp, "show b", %{confidence: 1.0})
    group_a = fetch_group(lp, "show a")
    group_b = fetch_group(lp, "show b")

    {:ok, view, _html} = live(conn, ~p"/import")

    dom_a = ImportCandidateGroup.dom_id(group_a)
    dom_b = ImportCandidateGroup.dom_id(group_b)

    # Expand Group A
    view |> element("#group-toggle-#{dom_a}") |> render_click()
    assert has_element?(view, "#member-#{candidate_a.id}")
    assert has_element?(view, "#group-toggle-#{dom_a} .hero-chevron-down")
    assert has_element?(view, "#group-toggle-#{dom_b} .hero-chevron-right")

    # Expand Group B -> Group A collapses, Group B expands
    view |> element("#group-toggle-#{dom_b}") |> render_click()
    assert has_element?(view, "#member-#{candidate_b.id}")
    refute has_element?(view, "#member-#{candidate_a.id}")
    assert has_element?(view, "#group-toggle-#{dom_a} .hero-chevron-right")
    assert has_element?(view, "#group-toggle-#{dom_b} .hero-chevron-down")
  end

  test "select all matching the filter accepts every ready group", %{conn: conn} do
    lp = library_path_fixture(%{type: "movies"})

    for n <- 1..3 do
      movie = media_item_fixture(%{type: "movie", tmdb_id: 1_000 + n})

      seed_group(lp, "r#{n}", %{
        media_type: "movie",
        provider_type: "tmdb",
        provider_id: to_string(movie.tmdb_id),
        title: movie.title,
        year: movie.year,
        confidence: 1.0,
        parsed_info: %{"type" => "movie"}
      })
    end

    seed_group(lp, "low", %{media_type: "movie", confidence: 0.7})

    {:ok, view, _html} = live(conn, ~p"/import")

    view |> element("#band-ready") |> render_click()
    view |> element("#select-all-matching") |> render_click()
    view |> element("#accept-selected") |> render_click()

    assert Repo.aggregate(from(f in Mydia.Library.MediaFile), :count) == 3
    assert ImportCandidates.count_pending() == 1
  end

  test "select all matching and clear both redraw every checkbox on screen", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})
    seed_group(lp, "a", %{confidence: 1.0})
    seed_group(lp, "b", %{confidence: 1.0})
    group_a = fetch_group(lp, "a")
    group_b = fetch_group(lp, "b")

    {:ok, view, _html} = live(conn, ~p"/import")

    dom_a = ImportCandidateGroup.dom_id(group_a)
    dom_b = ImportCandidateGroup.dom_id(group_b)

    refute has_element?(view, "#group-#{dom_a} input[type=checkbox][checked]")
    refute has_element?(view, "#group-#{dom_b} input[type=checkbox][checked]")

    view |> element("#band-ready") |> render_click()
    view |> element("#select-all-matching") |> render_click()

    # A `:filter`-mode selection touches no per-row state at all, so the only
    # way either checkbox can reflect it is if the handler re-inserts every
    # currently-rendered row into the stream. Asserting on the checkbox
    # itself (rather than just SelectionScope.count/1) is the point: the
    # count can be right in the socket while every box on screen stays
    # unchecked if that re-insert never happens.
    assert has_element?(view, "#group-#{dom_a} input[type=checkbox][checked]")
    assert has_element?(view, "#group-#{dom_b} input[type=checkbox][checked]")

    view |> element("#clear-selection") |> render_click()

    refute has_element?(view, "#group-#{dom_a} input[type=checkbox][checked]")
    refute has_element?(view, "#group-#{dom_b} input[type=checkbox][checked]")
  end

  test "accepting select-all-matching covers every matching group, not just one page",
       %{conn: conn} do
    lp = library_path_fixture(%{type: "movies", path: "/media/Movies"})
    # ImportCandidates' default page size is 50; 55 forces the filter-mode
    # accept to reach past a single page or this assertion catches it at 50.
    # A real (non-"local") provider per group, at a needs_attention
    # confidence, is deliberate: accept_group/2 refuses provider_type:
    # "local" outright ({:error, :local_show}), so a "local" fixture here
    # would make every click of #accept-selected a guaranteed no-op and this
    # test would stop proving anything about the page boundary at all.
    #
    # Each movie is pre-created locally (not resolved through a fresh relay
    # fetch) so promotion takes MetadataEnricher's "update existing item by
    # id" branch: MetadataStubProvider.fetch_by_id/3 always returns the same
    # canned movie regardless of the id requested, so 55 *new* creates driven
    # by a stub fetch would all race to persist the *same* stubbed tmdb_id
    # and only the first would ever land -- not a page-boundary bug, but a
    # fixture-shape trap this test fell into once already.
    for n <- 1..55 do
      movie = insert(:media_item, type: "movie", tmdb_id: 9000 + n)

      seed_group(lp, "g#{n}", %{
        media_type: "movie",
        provider_type: "tmdb",
        provider_id: to_string(movie.tmdb_id),
        confidence: 0.7,
        parsed_info: %{"type" => "movie"}
      })
    end

    {:ok, view, _html} = live(conn, ~p"/import")

    view |> element("#band-needs-attention") |> render_click()
    view |> element("#select-all-matching") |> render_click()
    assert has_element?(view, "#bulk-bar", "55 group(s) selected")

    view |> element("#accept-selected") |> render_click()

    assert Repo.aggregate(
             from(f in Mydia.Library.MediaFile, where: f.library_path_id == ^lp.id),
             :count
           ) == 55

    assert ImportCandidates.page(lp.id) == {[], nil}
  end

  test "keyset paging: next, next, prev covers the full set with no repeats", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})
    # 105 forces three pages at the default page size of 50 (50, 50, 5), so
    # next -> next lands on a genuinely different third page rather than
    # bouncing between two.
    for n <- 1..105, do: seed_group(lp, "p#{n}", %{confidence: 1.0})

    {:ok, view, _html} = live(conn, ~p"/import")

    page1 = rendered_group_ids(view)
    assert length(page1) == 50

    view |> element("#next-page") |> render_click()
    page2 = rendered_group_ids(view)
    assert length(page2) == 50

    view |> element("#next-page") |> render_click()
    page3 = rendered_group_ids(view)
    assert length(page3) == 5

    view |> element("#prev-page") |> render_click()
    assert rendered_group_ids(view) == page2

    all_ids = page1 ++ page2 ++ page3
    assert length(Enum.uniq(all_ids)) == 105
  end

  test "the picker shows only the selected library's groups and switches on click", %{
    conn: conn
  } do
    lp1 =
      library_path_fixture(%{
        type: "series",
        path: "/tmp/import_review_lib_a_#{System.unique_integer([:positive])}"
      })

    lp2 =
      library_path_fixture(%{
        type: "movies",
        path: "/tmp/import_review_lib_b_#{System.unique_integer([:positive])}"
      })

    seed_group(lp1, "library a group")
    seed_group(lp2, "library b group")
    a = fetch_group(lp1, "library a group")
    b = fetch_group(lp2, "library b group")

    {:ok, view, _html} = live(conn, ~p"/import")

    # `asc: path` breaks the tie between two otherwise-equal library paths,
    # so lib_a is the default selection.
    assert has_element?(view, "#group-#{ImportCandidateGroup.dom_id(a)}")
    refute has_element?(view, "#group-#{ImportCandidateGroup.dom_id(b)}")

    view |> element("#library-tab-#{lp2.id}") |> render_click()

    assert has_element?(view, "#group-#{ImportCandidateGroup.dom_id(b)}")
    refute has_element?(view, "#group-#{ImportCandidateGroup.dom_id(a)}")
  end

  test "navigating with type=movies selects the movie library in review panel", %{conn: conn} do
    lp1 =
      library_path_fixture(%{
        type: "series",
        path: "/tmp/import_review_lib_a_#{System.unique_integer([:positive])}"
      })

    lp2 =
      library_path_fixture(%{
        type: "movies",
        path: "/tmp/import_review_lib_b_#{System.unique_integer([:positive])}"
      })

    seed_group(lp1, "library a group")
    seed_group(lp2, "library b group")
    a = fetch_group(lp1, "library a group")
    b = fetch_group(lp2, "library b group")

    {:ok, view, _html} = live(conn, ~p"/import?type=movies")

    assert has_element?(view, "#group-#{ImportCandidateGroup.dom_id(b)}")
    refute has_element?(view, "#group-#{ImportCandidateGroup.dom_id(a)}")
    assert has_element?(view, "#library-tab-#{lp2.id}.tab-active")
  end

  test "navigating with type=tv selects the tv library in review panel", %{conn: conn} do
    lp1 =
      library_path_fixture(%{
        type: "movies",
        path: "/tmp/import_review_lib_a_#{System.unique_integer([:positive])}"
      })

    lp2 =
      library_path_fixture(%{
        type: "series",
        path: "/tmp/import_review_lib_b_#{System.unique_integer([:positive])}"
      })

    seed_group(lp1, "library a group")
    seed_group(lp2, "library b group")
    a = fetch_group(lp1, "library a group")
    b = fetch_group(lp2, "library b group")

    {:ok, view, _html} = live(conn, ~p"/import?type=tv")

    assert has_element?(view, "#group-#{ImportCandidateGroup.dom_id(b)}")
    refute has_element?(view, "#group-#{ImportCandidateGroup.dom_id(a)}")
    assert has_element?(view, "#library-tab-#{lp2.id}.tab-active")
  end

  test "the page issues no query on the disconnected render", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})
    seed_group(lp, "a")

    html = conn |> get(~p"/import") |> html_response(200)

    assert html =~ "Import"
    # A bare "group-" would also match Tailwind's unrelated `group-hover:` /
    # `group-has-checked:` variant classes already used by the run-control
    # form above this section, so the assertion targets the group row's own
    # DOM id pattern specifically.
    refute html =~ ~s(id="group-)
  end

  test "/review redirects to /import", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/import"}}} = live(conn, "/review")
  end

  test "a ready group is collapsed and a needs-attention group is expanded on load", %{
    conn: conn
  } do
    lp = library_path_fixture(%{type: "series"})
    seed_group(lp, "ready", %{confidence: 1.0})
    [attention_candidate] = seed_group(lp, "attention", %{confidence: 0.7})

    ready = fetch_group(lp, "ready")
    attention = fetch_group(lp, "attention")

    {:ok, view, _html} = live(conn, ~p"/import")

    dom_ready = ImportCandidateGroup.dom_id(ready)
    dom_attention = ImportCandidateGroup.dom_id(attention)

    assert has_element?(view, "#group-toggle-#{dom_ready} .hero-chevron-right")
    assert has_element?(view, "#group-toggle-#{dom_attention} .hero-chevron-down")

    # The attention group is visually open (chevron-down, asserted above),
    # but the page is bounded to loading members for only one group at a
    # time -- the one most recently clicked. Auto-expanding it on load must
    # not eagerly load its members, or the whole point of the bound is lost.
    refute has_element?(view, "#candidate-#{attention_candidate.id}")
  end

  test "changing the search resets the selection", %{conn: conn} do
    # Regression: select_library and select_band both reset the selection
    # because a selection made under one scope must not leak into another --
    # in :filter mode select_all_matching/1 captures the current :q, so a
    # stale selection would make SelectionScope.selected?/2 mark newly listed
    # rows as checked and accept_selected/dismiss_selected would act on
    # groups the search has already narrowed past. "search" had no such
    # reset.
    lp = library_path_fixture(%{type: "series"})
    seed_group(lp, "search-reset")

    {:ok, view, _html} = live(conn, ~p"/import")

    render_click(view, "toggle_group", %{"id" => "search-reset"})
    assert has_element?(view, "#bulk-bar", "1 group(s) selected")

    render_change(view, "search", %{"q" => "something else"})

    assert has_element?(view, "#bulk-bar", "0 group(s) selected")
  end

  test "a burst of import_candidates_changed broadcasts coalesces into one deferred refresh",
       %{conn: conn} do
    # A scanner run or a batch rematch can broadcast several times in quick
    # succession -- each one otherwise re-triggering refresh_counts/1's full
    # band_counts/1 read on every open page. Prove the fix black-box: two
    # broadcasts arriving back to back must not update the counts until the
    # debounce window elapses, and must then reflect state exactly once, not
    # twice.
    lp = library_path_fixture(%{type: "series"})
    seed_group(lp, "initial")

    {:ok, view, _html} = live(conn, ~p"/import")

    assert has_element?(view, "#band-all .badge", "1")

    seed_group(lp, "second")

    send(view.pid, {:import_candidates_changed, lp.id})
    send(view.pid, {:import_candidates_changed, lp.id})

    # Still coalescing: the deferred refresh has not fired yet, so the second
    # group is not reflected in the badge count.
    assert has_element?(view, "#band-all .badge", "1")
    assert :sys.get_state(view.pid).socket.assigns.refresh_scheduled?

    Process.sleep(600)
    render(view)

    refute :sys.get_state(view.pid).socket.assigns.refresh_scheduled?
    assert has_element?(view, "#band-all .badge", "2")
  end

  test "the nav badge shows the pending group count", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})
    seed_group(lp, "a")
    seed_group(lp, "b")

    {:ok, view, _html} = live(conn, ~p"/import")

    assert has_element?(view, "#nav-import-badge", "2")
  end

  # `accept_selected`, `dismiss_selected` and `create_local_show` all write to
  # the library (flip a candidate's dismissal, link a file, or create a
  # MediaItem), same as `start_run`/`stop_run` on this same LiveView -- but,
  # unlike those two, shipped with no authorization guard at all. `/import`
  # sits behind `:require_authenticated` only, not a role check, so a
  # readonly or guest account could reach any of them.
  test "readonly users cannot accept selected groups", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})
    seed_group(lp, "readonly-accept", %{confidence: 1.0})

    readonly_conn = log_in_user(conn, user_fixture(%{role: "readonly"}))

    {:ok, view, _html} = live(readonly_conn, ~p"/import")

    render_click(view, "toggle_group", %{"id" => "readonly-accept"})
    render_click(view, "accept_selected", %{})

    assert fetch_group(lp, "readonly-accept")
  end

  test "readonly users cannot dismiss selected groups", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})
    seed_group(lp, "readonly-dismiss")

    readonly_conn = log_in_user(conn, user_fixture(%{role: "readonly"}))

    {:ok, view, _html} = live(readonly_conn, ~p"/import")

    render_click(view, "toggle_group", %{"id" => "readonly-dismiss"})
    render_click(view, "dismiss_selected", %{})

    assert fetch_group(lp, "readonly-dismiss")
  end

  test "readonly users cannot create a local show from a no-match folder", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})

    candidate =
      import_candidate_fixture(%{
        library_path_id: lp.id,
        anchor_key: "readonly show",
        relative_path: "Readonly Show (2023)/Season 01/ep1.mkv",
        media_type: "tv_show",
        parsed_info: %{"season" => 1, "episodes" => [1]}
      })

    readonly_conn = log_in_user(conn, user_fixture(%{role: "readonly"}))

    {:ok, view, _html} = live(readonly_conn, ~p"/import")

    render_click(view, "create_local_show", %{"id" => "readonly show"})

    assert Repo.aggregate(Mydia.Media.MediaItem, :count) == 0
    assert Repo.get(ImportCandidate, candidate.id)
    refute Repo.reload!(candidate).provider_type == "local"
  end

  test "readonly users cannot restore selected ignored groups", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    seed_group(lp, "readonly-restore", %{dismissed_at: now})

    readonly_conn = log_in_user(conn, user_fixture(%{role: "readonly"}))
    {:ok, view, _html} = live(readonly_conn, ~p"/import")

    render_click(view, "select_band", %{"band" => "ignored"})
    render_click(view, "toggle_group", %{"id" => "readonly-restore"})
    render_click(view, "restore_selected", %{})

    assert fetch_group(lp, "readonly-restore", status: "ignored")
  end

  test "readonly users cannot batch rematch", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})

    candidate =
      import_candidate_fixture(%{
        library_path_id: lp.id,
        anchor_key: "readonly batch rematch",
        relative_path: "Readonly Show/Season 01/Readonly Show - S01E01.mkv",
        provider_id: "before",
        provider_type: "tvdb",
        title: "Before",
        confidence: 0.5
      })

    readonly_conn = log_in_user(conn, user_fixture(%{role: "readonly"}))
    {:ok, view, _html} = live(readonly_conn, ~p"/import")

    render_click(view, "toggle_group", %{"id" => "readonly batch rematch"})
    render_click(view, "rematch_selected", %{})

    assert Repo.reload!(candidate).provider_id == "before"
  end

  describe "Change match" do
    defp seed_wrong_match(lp) do
      candidate =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          anchor_key: "patamuse",
          relative_path: "Patamuse (2018)/Season 01/ep1.mkv",
          provider_id: "9999",
          provider_type: "tvdb",
          title: "The Peter Potamus Show",
          year: 1964,
          media_type: "tv_show",
          confidence: 0.703,
          parsed_info: %{"season" => 1, "episodes" => [1]}
        })

      {fetch_group(lp, "patamuse"), candidate}
    end

    test "the button reads Change match on a matched group and Identify on a no-match one",
         %{conn: conn} do
      lp = library_path_fixture(%{type: "series"})
      {matched, _candidate} = seed_wrong_match(lp)
      seed_group(lp, "no-match", %{provider_id: nil, confidence: nil})
      no_match = fetch_group(lp, "no-match")

      {:ok, view, _html} = live(conn, ~p"/import")

      assert has_element?(
               view,
               "#change-match-#{ImportCandidateGroup.dom_id(matched)}",
               "Change match"
             )

      assert has_element?(
               view,
               "#change-match-#{ImportCandidateGroup.dom_id(no_match)}",
               "Identify"
             )
    end

    test "opens prefilled with the group's suggested title and shows relay results",
         %{conn: conn} do
      lp = library_path_fixture(%{type: "series"})
      {group, _candidate} = seed_wrong_match(lp)

      {:ok, view, _html} = live(conn, ~p"/import")

      view
      |> element("#change-match-#{ImportCandidateGroup.dom_id(group)}")
      |> render_click()

      render_async(view)

      assert has_element?(
               view,
               ~s(#match-search-form input[value="The Peter Potamus Show"])
             )

      series_id = MetadataStubProvider.series_tvdb_id()

      assert has_element?(
               view,
               "#match-result-#{series_id}-tvdb",
               MetadataStubProvider.series_title()
             )
    end

    test "selecting a result applies it to the group and every unresolved member",
         %{conn: conn} do
      lp = library_path_fixture(%{type: "series"})
      {group, candidate} = seed_wrong_match(lp)
      series_id = MetadataStubProvider.series_tvdb_id()
      series_title = MetadataStubProvider.series_title()

      {:ok, view, _html} = live(conn, ~p"/import")

      view
      |> element("#change-match-#{ImportCandidateGroup.dom_id(group)}")
      |> render_click()

      render_async(view)

      view |> element("#match-result-#{series_id}-tvdb") |> render_click()

      assert has_element?(view, "#flash-info", "Updated the match")
      refute has_element?(view, "#match-results")

      # The group's row re-renders as :ready once the correction lands --
      # a human's pick is at least as trustworthy as an automatic match.
      reloaded_group = fetch_group(lp, "patamuse")

      assert has_element?(
               view,
               "#group-#{ImportCandidateGroup.dom_id(reloaded_group)} .badge-success"
             )

      assert reloaded_group.provider_id == to_string(series_id)
      assert reloaded_group.provider_type == "tvdb"
      assert reloaded_group.suggested_title == series_title

      reloaded_candidate = Repo.reload!(candidate)
      assert reloaded_candidate.provider_id == to_string(series_id)
      assert reloaded_candidate.title == series_title
      assert reloaded_candidate.parsed_info == %{"season" => 1, "episodes" => [1]}
    end

    test "selecting a result for a group that vanished mid-review flashes instead of crashing",
         %{conn: conn} do
      # The render-then-click race this project has already fixed elsewhere
      # (open_match_search/2 uses the same nil-safe get_group/3): another
      # session or a concurrent run removes every candidate in the anchor
      # between opening the modal and picking a result.
      lp = library_path_fixture(%{type: "series"})
      {_group, candidate} = seed_wrong_match(lp)
      series_id = MetadataStubProvider.series_tvdb_id()

      {:ok, view, _html} = live(conn, ~p"/import")

      view
      |> element("#change-match-#{ImportCandidateGroup.dom_id(fetch_group(lp, "patamuse"))}")
      |> render_click()

      render_async(view)

      Repo.delete!(candidate)

      view |> element("#match-result-#{series_id}-tvdb") |> render_click()

      assert Process.alive?(view.pid)
      assert has_element?(view, "#flash-error", "no longer available")
      refute has_element?(view, "#match-results")
    end

    test "closing without selecting leaves the group untouched", %{conn: conn} do
      lp = library_path_fixture(%{type: "series"})
      {group, candidate} = seed_wrong_match(lp)

      {:ok, view, _html} = live(conn, ~p"/import")

      view
      |> element("#change-match-#{ImportCandidateGroup.dom_id(group)}")
      |> render_click()

      render_async(view)

      view |> element("#match-search-modal button", "Cancel") |> render_click()

      refute has_element?(view, "#match-results")
      assert Repo.reload!(candidate).provider_id == "9999"
    end

    test "applying a corrected match removes the row from needs_attention filter", %{conn: conn} do
      lp = library_path_fixture(%{type: "series"})
      {group, _candidate} = seed_wrong_match(lp)
      series_id = MetadataStubProvider.series_tvdb_id()

      {:ok, view, _html} = live(conn, ~p"/import")

      # Filter to the "needs_attention" band
      view |> element("#band-needs-attention") |> render_click()

      dom_id = ImportCandidateGroup.dom_id(group)

      # Verify the group is visible in this band
      assert has_element?(view, "#group-#{dom_id}")

      # Open the match search modal and select a result
      view |> element("#change-match-#{dom_id}") |> render_click()
      render_async(view)

      view |> element("#match-result-#{series_id}-tvdb") |> render_click()

      # The group's row should no longer be present because it moved to :ready band
      refute has_element?(view, "#group-#{dom_id}")
    end
  end

  test "readonly users cannot apply a chosen match", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})

    candidate =
      import_candidate_fixture(%{
        library_path_id: lp.id,
        anchor_key: "patamuse",
        relative_path: "Patamuse (2018)/Season 01/ep1.mkv",
        provider_id: "9999",
        provider_type: "tvdb",
        title: "The Peter Potamus Show",
        confidence: 0.703
      })

    group = fetch_group(lp, "patamuse")
    readonly_conn = log_in_user(conn, user_fixture(%{role: "readonly"}))

    {:ok, view, _html} = live(readonly_conn, ~p"/import")

    view
    |> element("#change-match-#{ImportCandidateGroup.dom_id(group)}")
    |> render_click()

    render_async(view)

    series_id = MetadataStubProvider.series_tvdb_id()
    view |> element("#match-result-#{series_id}-tvdb") |> render_click()

    assert Repo.reload!(candidate).provider_id == "9999"
  end

  describe "the Ignored view" do
    defp seed_dismissed(lp, anchor_key, attrs \\ %{}) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      seed_group(lp, anchor_key, Map.put(attrs, :dismissed_at, now))
    end

    test "the Ignored chip counts ignored groups and the pending chips exclude them",
         %{conn: conn} do
      lp = library_path_fixture(%{type: "series"})
      seed_group(lp, "pending", %{confidence: 1.0})
      seed_dismissed(lp, "ignored-one")
      seed_dismissed(lp, "ignored-two")

      {:ok, view, _html} = live(conn, ~p"/import")

      assert has_element?(view, "#band-ignored", "2")
      assert has_element?(view, "#band-all", "1")
      assert has_element?(view, "#band-ready", "1")
    end

    test "selecting the Ignored chip shows ignored groups and hides pending ones",
         %{conn: conn} do
      lp = library_path_fixture(%{type: "series"})
      seed_group(lp, "pending", %{confidence: 1.0})
      seed_dismissed(lp, "ignored")

      pending = fetch_group(lp, "pending")
      ignored = fetch_group(lp, "ignored", status: "ignored")

      {:ok, view, _html} = live(conn, ~p"/import")

      assert has_element?(view, "#group-#{ImportCandidateGroup.dom_id(pending)}")
      refute has_element?(view, "#group-#{ImportCandidateGroup.dom_id(ignored)}")

      view |> element("#band-ignored") |> render_click()

      refute has_element?(view, "#group-#{ImportCandidateGroup.dom_id(pending)}")
      assert has_element?(view, "#group-#{ImportCandidateGroup.dom_id(ignored)}")
    end

    test "an ignored row offers Restore instead of the normal group controls",
         %{conn: conn} do
      lp = library_path_fixture(%{type: "series"})
      seed_dismissed(lp, "ignored")
      ignored = fetch_group(lp, "ignored", status: "ignored")

      {:ok, view, _html} = live(conn, ~p"/import")
      view |> element("#band-ignored") |> render_click()

      dom_id = ImportCandidateGroup.dom_id(ignored)

      assert has_element?(view, "#restore-#{dom_id}")
      assert has_element?(view, "#group-#{dom_id} input[type=checkbox]")
      refute has_element?(view, "#change-match-#{dom_id}")
      refute has_element?(view, "#create-local-#{dom_id}")
    end

    test "restoring a group returns it to pending and moves it back off the Ignored view",
         %{conn: conn} do
      lp = library_path_fixture(%{type: "series"})
      seed_dismissed(lp, "ignored")
      ignored = fetch_group(lp, "ignored", status: "ignored")

      {:ok, view, _html} = live(conn, ~p"/import")
      view |> element("#band-ignored") |> render_click()

      view
      |> element("#restore-#{ImportCandidateGroup.dom_id(ignored)}")
      |> render_click()

      assert has_element?(view, "#flash-info", "Restored")
      refute has_element?(view, "#group-#{ImportCandidateGroup.dom_id(ignored)}")
      assert fetch_group(lp, "ignored")
    end

    test "an ignored group accepted then re-viewed as pending shows normal controls again",
         %{conn: conn} do
      lp = library_path_fixture(%{type: "series"})
      seed_dismissed(lp, "roundtrip", %{confidence: 1.0})

      {:ok, view, _html} = live(conn, ~p"/import")
      view |> element("#band-ignored") |> render_click()

      view
      |> element(
        "#restore-#{ImportCandidateGroup.dom_id(fetch_group(lp, "roundtrip", status: "ignored"))}"
      )
      |> render_click()

      view |> element("#band-all") |> render_click()

      group = fetch_group(lp, "roundtrip")

      assert has_element?(
               view,
               "#group-#{ImportCandidateGroup.dom_id(group)} input[type=checkbox]"
             )
    end
  end

  test "readonly users cannot restore an ignored group", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    seed_group(lp, "readonly-restore", %{dismissed_at: now})

    readonly_conn = log_in_user(conn, user_fixture(%{role: "readonly"}))

    {:ok, view, _html} = live(readonly_conn, ~p"/import")
    view |> element("#band-ignored") |> render_click()

    render_click(view, "restore_group", %{"id" => "readonly-restore"})

    assert fetch_group(lp, "readonly-restore", status: "ignored")
  end

  describe "member episode editing" do
    test "renders filename, folder, matched episode badge, and inline S/E inputs", %{conn: conn} do
      lp = library_path_fixture(%{type: "series"})

      candidate =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          anchor_key: "my show",
          relative_path: "My Show/Season 01/My.Show.S01E03.1080p.mkv",
          confidence: 1.0,
          title: "My Show",
          parsed_info: %{"season" => 1, "episodes" => [3]}
        })

      group = fetch_group(lp, "my show")

      {:ok, view, _html} = live(conn, ~p"/import")

      view
      |> element("#group-toggle-#{ImportCandidateGroup.dom_id(group)}")
      |> render_click()

      assert has_element?(view, "#member-#{candidate.id}", "My.Show.S01E03.1080p.mkv")
      assert has_element?(view, "#candidate-#{candidate.id}", "My Show/Season 01")
      assert has_element?(view, "#candidate-#{candidate.id}", "S01E03")
      assert has_element?(view, "#member-form-#{candidate.id} input[name=season][value='1']")
      assert has_element?(view, "#member-form-#{candidate.id} input[name=episode][value='3']")
    end

    test "changing season and episode updates candidate parsed_info and LiveView UI", %{
      conn: conn
    } do
      lp = library_path_fixture(%{type: "series"})

      [candidate] =
        seed_group(lp, "my show", %{
          confidence: 1.0,
          title: "My Show"
        })

      group = fetch_group(lp, "my show")

      {:ok, view, _html} = live(conn, ~p"/import")

      view
      |> element("#group-toggle-#{ImportCandidateGroup.dom_id(group)}")
      |> render_click()

      assert has_element?(view, "#candidate-#{candidate.id}", "No episode")

      view
      |> element("#member-form-#{candidate.id}")
      |> render_change(%{"candidate_id" => candidate.id, "season" => "2", "episode" => "8"})

      assert has_element?(view, "#candidate-#{candidate.id}", "S02E08")

      reloaded = Repo.reload!(candidate)
      assert reloaded.parsed_info["season"] == 2
      assert reloaded.parsed_info["episodes"] == [8]
    end

    test "readonly users cannot update member episodes", %{conn: conn} do
      lp = library_path_fixture(%{type: "series"})
      [candidate] = seed_group(lp, "show", %{confidence: 1.0})

      readonly_conn = log_in_user(conn, user_fixture(%{role: "readonly"}))
      {:ok, view, _html} = live(readonly_conn, ~p"/import")

      render_change(view, "update_member_episode", %{
        "candidate_id" => candidate.id,
        "season" => "1",
        "episode" => "1"
      })

      assert Repo.reload!(candidate).parsed_info in [nil, %{}]
    end

    test "movie groups do not render season span badges or episode editing forms", %{conn: conn} do
      lp = library_path_fixture(%{type: "movies"})

      [candidate] =
        seed_group(lp, "inception", %{
          media_type: "movie",
          confidence: 1.0,
          relative_path: "Inception (2010)/Inception.2010.1080p.mkv"
        })

      group = fetch_group(lp, "inception")

      {:ok, view, _html} = live(conn, ~p"/import")

      view
      |> element("#group-toggle-#{ImportCandidateGroup.dom_id(group)}")
      |> render_click()

      assert has_element?(view, "#member-#{candidate.id}", "Inception.2010.1080p.mkv")
      refute has_element?(view, "#member-form-#{candidate.id}")
      refute has_element?(view, "#candidate-#{candidate.id}", "No episode")
      refute has_element?(view, "#group-toggle-#{ImportCandidateGroup.dom_id(group)}", "S1")
    end
  end

  describe "batch actions" do
    test "select page selects all visible groups on current page", %{conn: conn} do
      lp = library_path_fixture(%{type: "series"})
      seed_group(lp, "g1", %{title: "Show 1"})
      seed_group(lp, "g2", %{title: "Show 2"})
      g1 = fetch_group(lp, "g1")
      g2 = fetch_group(lp, "g2")

      {:ok, view, _html} = live(conn, ~p"/import")

      render_click(view, "select_band", %{"band" => "all"})
      # Clicking select current page
      render_click(view, "select_current_page", %{})

      assert has_element?(view, "#bulk-bar", "2 group(s) selected")

      assert has_element?(
               view,
               "#group-#{ImportCandidateGroup.dom_id(g1)} input[type=checkbox]:checked"
             )

      assert has_element?(
               view,
               "#group-#{ImportCandidateGroup.dom_id(g2)} input[type=checkbox]:checked"
             )
    end

    test "ignored view supports selection, select-all, and batch restore", %{conn: conn} do
      lp = library_path_fixture(%{type: "series"})
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      seed_group(lp, "ig1", %{title: "Ignored 1", dismissed_at: now})
      seed_group(lp, "ig2", %{title: "Ignored 2", dismissed_at: now})
      g1 = fetch_group(lp, "ig1", status: "ignored")
      g2 = fetch_group(lp, "ig2", status: "ignored")

      {:ok, view, _html} = live(conn, ~p"/import")

      render_click(view, "select_band", %{"band" => "ignored"})

      assert has_element?(view, "#restore-#{ImportCandidateGroup.dom_id(g1)}")
      assert has_element?(view, "#restore-#{ImportCandidateGroup.dom_id(g2)}")

      # Toggle individual ignored group
      render_click(view, "toggle_group", %{"id" => "ig1"})
      assert has_element?(view, "#bulk-bar", "1 group(s) selected")
      assert has_element?(view, "#restore-selected", "Restore 1")
      refute has_element?(view, "#accept-selected")

      # Select all matching
      render_click(view, "select_all_matching", %{})
      assert has_element?(view, "#bulk-bar", "2 group(s) selected")
      assert has_element?(view, "#restore-selected", "Restore 2")

      # Click restore selected
      render_click(view, "restore_selected", %{})

      assert render(view) =~ "Restored 2 group(s) to pending."
      assert fetch_group(lp, "ig1")
      assert fetch_group(lp, "ig2")
    end

    test "local show creation is available per row, not as a batch action", %{conn: conn} do
      lp = library_path_fixture(%{type: "series", path: "/media/Series"})

      seed_group(lp, "no-match-1", %{
        title: "Custom Show One (2020)",
        provider_id: nil,
        confidence: nil
      })

      g1 = fetch_group(lp, "no-match-1")

      {:ok, view, _html} = live(conn, ~p"/import")

      render_click(view, "select_band", %{"band" => "no_match"})
      render_click(view, "toggle_group", %{"id" => "no-match-1"})

      refute has_element?(view, "#create-local-selected")

      assert has_element?(
               view,
               "#create-local-#{ImportCandidateGroup.dom_id(g1)}",
               "Create show from folder"
             )
    end

    test "batch rematch re-runs matcher on selected groups", %{conn: conn} do
      lp = library_path_fixture(%{type: "series", path: "/media/Series"})

      candidate =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          anchor_key: "stub series",
          relative_path: "Stub Series (2020)/Season 01/Stub Series - S01E01.mkv",
          last_error: "no_match"
        })

      {:ok, view, _html} = live(conn, ~p"/import")

      render_click(view, "toggle_group", %{"id" => "stub series"})
      assert has_element?(view, "#rematch-selected")

      render_click(view, "rematch_selected", %{})
      render_async(view)

      assert render(view) =~ "Re-matched 1 file(s)."

      reloaded = Repo.reload!(candidate)
      assert reloaded.provider_id == to_string(MetadataStubProvider.series_tvdb_id())
    end
  end
end
