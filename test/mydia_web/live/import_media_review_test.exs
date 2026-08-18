defmodule MydiaWeb.ImportMediaReviewTest do
  use MydiaWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.MetadataStub
  import Mydia.SettingsFixtures

  alias Mydia.Library.ImportGroup
  alias Mydia.MetadataStubProvider
  alias Mydia.Repo

  setup :setup_metadata_stub

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  defp seed_group(lp, attrs) do
    %ImportGroup{}
    |> ImportGroup.changeset(
      Map.merge(
        %{
          library_path_id: lp.id,
          anchor_path: "Show",
          cluster_key: "show",
          display_title: "Show",
          file_count: 10,
          unresolved_count: 10,
          provider_id: "1",
          suggested_title: "Show",
          min_confidence: 1.0,
          status: "pending"
        },
        Map.new(attrs)
      )
    )
    |> Repo.insert!()
  end

  # Stamps `count` real, unresolved member files onto `group` (rather than
  # just trusting its `file_count` rollup column), so a test that claims to
  # show one row per group instead of one per file actually has files to
  # prove that with.
  defp seed_members(group, lp, count) do
    for n <- 1..count do
      file =
        orphaned_media_file_fixture(%{
          library_path_id: lp.id,
          relative_path: "#{group.display_title}/file-#{n}.mkv"
        })

      Repo.update_all(from(f in Mydia.Library.MediaFile, where: f.id == ^file.id),
        set: [import_group_id: group.id]
      )

      file
    end
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

  test "renders one row per group, not one row per member file", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})
    a = seed_group(lp, cluster_key: "a", display_title: "Cornemuse", file_count: 3)
    b = seed_group(lp, cluster_key: "b", display_title: "Pin-Pon", file_count: 3)
    seed_members(a, lp, 3)
    seed_members(b, lp, 3)

    {:ok, view, _html} = live(conn, ~p"/import")

    assert has_element?(view, "#group-#{a.id}")
    assert has_element?(view, "#group-#{b.id}")
  end

  test "shows band counts", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})
    seed_group(lp, cluster_key: "a", min_confidence: 1.0)
    seed_group(lp, cluster_key: "b", min_confidence: 0.7)
    seed_group(lp, cluster_key: "c", provider_id: nil, min_confidence: nil)

    {:ok, view, _html} = live(conn, ~p"/import")

    assert has_element?(view, "#band-ready", "1")
    assert has_element?(view, "#band-needs-attention", "1")
    assert has_element?(view, "#band-no-match", "1")
  end

  test "renders the evidence label next to the suggestion, not just the confidence number",
       %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})

    exact =
      seed_group(lp,
        cluster_key: "exact",
        min_confidence: 1.0,
        evidence: %{"kind" => "exact_title", "candidates" => 1}
      )

    fuzzy =
      seed_group(lp,
        cluster_key: "fuzzy",
        min_confidence: 0.7,
        evidence: %{"kind" => "fuzzy", "candidates" => 3}
      )

    {:ok, view, _html} = live(conn, ~p"/import")

    assert has_element?(view, "#group-#{exact.id}", "exact title match")
    assert has_element?(view, "#group-#{fuzzy.id}", "fuzzy title, 3 candidates")
  end

  test "a group with no evidence kind renders without crashing", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})
    seed_group(lp, cluster_key: "no-evidence")

    assert {:ok, _view, _html} = live(conn, ~p"/import")
  end

  test "the create-local-show button only appears on a no-match group's row", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})
    matched = seed_group(lp, cluster_key: "matched", min_confidence: 1.0)
    no_match = seed_group(lp, cluster_key: "no-match", provider_id: nil, min_confidence: nil)

    {:ok, view, _html} = live(conn, ~p"/import")

    refute has_element?(view, "#create-local-#{matched.id}")
    assert has_element?(view, "#create-local-#{no_match.id}")
  end

  test "creating a local show from a no-match group's folder links its files and clears it from the queue",
       %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})

    group =
      seed_group(lp,
        cluster_key: "local",
        display_title: "Les mots de Passe-Partout (2023)",
        file_count: 1,
        unresolved_count: 1,
        provider_id: nil,
        min_confidence: nil
      )

    file =
      orphaned_media_file_fixture(%{
        library_path_id: lp.id,
        relative_path: "Les mots de Passe-Partout (2023)/Season 01/ep1.mkv"
      })

    Repo.update_all(from(f in Mydia.Library.MediaFile, where: f.id == ^file.id),
      set: [import_group_id: group.id]
    )

    %Mydia.Library.MatchCandidate{}
    |> Mydia.Library.MatchCandidate.changeset(%{
      media_file_id: file.id,
      rank: 0,
      parsed_info: %{"season" => 1, "episodes" => [1]}
    })
    |> Repo.insert!()

    {:ok, view, _html} = live(conn, ~p"/import")

    view |> element("#create-local-#{group.id}") |> render_click()

    assert has_element?(view, "#flash-info", "Les mots de Passe-Partout")
    refute has_element?(view, "#group-#{group.id}")

    reloaded_group = Repo.reload!(group)
    assert reloaded_group.status == "applied"
    assert reloaded_group.provider_type == "local"
    assert Repo.reload!(file).episode_id
  end

  test "creating a local show reports leftover unnumbered files rather than a clean success",
       %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})

    group =
      seed_group(lp,
        cluster_key: "local-partial",
        display_title: "L'univers des Coucou (2023)",
        file_count: 2,
        unresolved_count: 2,
        provider_id: nil,
        min_confidence: nil
      )

    numbered_file =
      orphaned_media_file_fixture(%{
        library_path_id: lp.id,
        relative_path: "L'univers des Coucou (2023)/Season 01/ep1.mkv"
      })

    unnumbered_file =
      orphaned_media_file_fixture(%{
        library_path_id: lp.id,
        relative_path: "L'univers des Coucou (2023)/Season 01/bonus.mkv"
      })

    Repo.update_all(
      from(f in Mydia.Library.MediaFile, where: f.id in [^numbered_file.id, ^unnumbered_file.id]),
      set: [import_group_id: group.id]
    )

    %Mydia.Library.MatchCandidate{}
    |> Mydia.Library.MatchCandidate.changeset(%{
      media_file_id: numbered_file.id,
      rank: 0,
      parsed_info: %{"season" => 1, "episodes" => [1]}
    })
    |> Repo.insert!()

    %Mydia.Library.MatchCandidate{}
    |> Mydia.Library.MatchCandidate.changeset(%{
      media_file_id: unnumbered_file.id,
      rank: 0,
      parsed_info: %{}
    })
    |> Repo.insert!()

    {:ok, view, _html} = live(conn, ~p"/import")

    view |> element("#create-local-#{group.id}") |> render_click()

    assert has_element?(view, "#flash-info", "linked 1 of 2 files")
    assert has_element?(view, "#flash-info", "1 had no episode number")

    # A partially-linked group stays "pending" (see ImportGroups.create_local_show/1),
    # precisely so it stays visible here instead of vanishing along with the file it
    # could not link -- it just no longer offers the same button, since it is no
    # longer :no_match (it now carries a provider identity, so it bands as
    # :needs_attention with min_confidence still nil).
    assert has_element?(view, "#group-#{group.id}")
    refute has_element?(view, "#create-local-#{group.id}")

    reloaded_group = Repo.reload!(group)
    assert reloaded_group.status == "pending"
    assert reloaded_group.unresolved_count == 1
    assert reloaded_group.provider_type == "local"
    assert Repo.reload!(numbered_file).episode_id
    refute Repo.reload!(unnumbered_file).episode_id
  end

  test "a second click on create-local-show is refused instead of creating a duplicate show",
       %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})

    group =
      seed_group(lp,
        cluster_key: "local-double-click",
        display_title: "Les mots de Passe-Partout (2023)",
        file_count: 1,
        unresolved_count: 1,
        provider_id: nil,
        min_confidence: nil
      )

    file =
      orphaned_media_file_fixture(%{
        library_path_id: lp.id,
        relative_path: "Les mots de Passe-Partout (2023)/Season 01/ep1.mkv"
      })

    Repo.update_all(from(f in Mydia.Library.MediaFile, where: f.id == ^file.id),
      set: [import_group_id: group.id]
    )

    %Mydia.Library.MatchCandidate{}
    |> Mydia.Library.MatchCandidate.changeset(%{
      media_file_id: file.id,
      rank: 0,
      parsed_info: %{"season" => 1, "episodes" => [1]}
    })
    |> Repo.insert!()

    {:ok, view, _html} = live(conn, ~p"/import")

    view |> element("#create-local-#{group.id}") |> render_click()
    assert has_element?(view, "#flash-info", "Les mots de Passe-Partout")

    # No `phx-disable-with` guards the button, so the id is still a valid
    # target for a stale or replayed event even though the row itself has
    # already dropped out of the stream.
    render_click(view, "create_local_show", %{"id" => group.id})

    assert has_element?(view, "#flash-info", "already created")
    assert Repo.aggregate(Mydia.Media.MediaItem, :count) == 1
  end

  test "a ready group renders collapsed and expands on click", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})
    group = seed_group(lp, min_confidence: 1.0)

    file =
      orphaned_media_file_fixture(%{
        library_path_id: lp.id,
        relative_path: "Show/Season 01/a.mkv"
      })

    Repo.update_all(Mydia.Library.MediaFile, set: [import_group_id: group.id])

    {:ok, view, _html} = live(conn, ~p"/import")

    refute has_element?(view, "#member-#{file.id}")

    view |> element("#group-toggle-#{group.id}") |> render_click()

    assert has_element?(view, "#member-#{file.id}")
  end

  test "expanding another group collapses the previously expanded group", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})
    group_a = seed_group(lp, cluster_key: "a", display_title: "Show A", min_confidence: 1.0)
    group_b = seed_group(lp, cluster_key: "b", display_title: "Show B", min_confidence: 1.0)

    file_a =
      orphaned_media_file_fixture(%{
        library_path_id: lp.id,
        relative_path: "Show A/Season 01/a.mkv"
      })

    file_b =
      orphaned_media_file_fixture(%{
        library_path_id: lp.id,
        relative_path: "Show B/Season 01/b.mkv"
      })

    Repo.update_all(from(f in Mydia.Library.MediaFile, where: f.id == ^file_a.id),
      set: [import_group_id: group_a.id]
    )

    Repo.update_all(from(f in Mydia.Library.MediaFile, where: f.id == ^file_b.id),
      set: [import_group_id: group_b.id]
    )

    {:ok, view, _html} = live(conn, ~p"/import")

    # Expand Group A
    view |> element("#group-toggle-#{group_a.id}") |> render_click()
    assert has_element?(view, "#member-#{file_a.id}")
    assert has_element?(view, "#group-toggle-#{group_a.id} .hero-chevron-down")
    assert has_element?(view, "#group-toggle-#{group_b.id} .hero-chevron-right")

    # Expand Group B -> Group A collapses, Group B expands
    view |> element("#group-toggle-#{group_b.id}") |> render_click()
    assert has_element?(view, "#member-#{file_b.id}")
    refute has_element?(view, "#member-#{file_a.id}")
    assert has_element?(view, "#group-toggle-#{group_a.id} .hero-chevron-right")
    assert has_element?(view, "#group-toggle-#{group_b.id} .hero-chevron-down")
  end

  test "select all matching the filter accepts every ready group", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})
    for n <- 1..3, do: seed_group(lp, cluster_key: "r#{n}", min_confidence: 1.0)
    seed_group(lp, cluster_key: "low", min_confidence: 0.7)

    {:ok, view, _html} = live(conn, ~p"/import")

    view |> element("#band-ready") |> render_click()
    view |> element("#select-all-matching") |> render_click()
    view |> element("#accept-selected") |> render_click()

    assert Repo.aggregate(
             from(g in ImportGroup, where: g.status == "accepted"),
             :count
           ) == 3
  end

  test "select all matching and clear both redraw every checkbox on screen", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})
    a = seed_group(lp, cluster_key: "a", min_confidence: 1.0)
    b = seed_group(lp, cluster_key: "b", min_confidence: 1.0)

    {:ok, view, _html} = live(conn, ~p"/import")

    refute has_element?(view, "#group-#{a.id} input[type=checkbox][checked]")
    refute has_element?(view, "#group-#{b.id} input[type=checkbox][checked]")

    view |> element("#band-ready") |> render_click()
    view |> element("#select-all-matching") |> render_click()

    # A `:filter`-mode selection touches no per-row state at all, so the only
    # way either checkbox can reflect it is if the handler re-inserts every
    # currently-rendered row into the stream. Asserting on the checkbox
    # itself (rather than just SelectionScope.count/1) is the point: the
    # count can be right in the socket while every box on screen stays
    # unchecked if that re-insert never happens.
    assert has_element?(view, "#group-#{a.id} input[type=checkbox][checked]")
    assert has_element?(view, "#group-#{b.id} input[type=checkbox][checked]")

    view |> element("#clear-selection") |> render_click()

    refute has_element?(view, "#group-#{a.id} input[type=checkbox][checked]")
    refute has_element?(view, "#group-#{b.id} input[type=checkbox][checked]")
  end

  test "accepting select-all-matching covers every matching group, not just one page",
       %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})
    # ImportGroups' default page size is 50; 55 forces the filter-mode accept
    # to reach past a single page or this assertion catches it at 50.
    for n <- 1..55, do: seed_group(lp, cluster_key: "g#{n}", file_count: n, min_confidence: 1.0)

    {:ok, view, _html} = live(conn, ~p"/import")

    view |> element("#band-ready") |> render_click()
    view |> element("#select-all-matching") |> render_click()
    view |> element("#accept-selected") |> render_click()

    assert Repo.aggregate(
             from(g in ImportGroup, where: g.status == "accepted"),
             :count
           ) == 55
  end

  test "keyset paging: next, next, prev covers the full set with no repeats", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})
    # 105 forces three pages at the default page size of 50 (50, 50, 5), so
    # next -> next lands on a genuinely different third page rather than
    # bouncing between two.
    for n <- 1..105, do: seed_group(lp, cluster_key: "p#{n}", file_count: n, min_confidence: 1.0)

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

    a = seed_group(lp1, cluster_key: "a", display_title: "Library A Group")
    b = seed_group(lp2, cluster_key: "b", display_title: "Library B Group")

    {:ok, view, _html} = live(conn, ~p"/import")

    # `asc: path` breaks the tie between two otherwise-equal library paths,
    # so lib_a is the default selection.
    assert has_element?(view, "#group-#{a.id}")
    refute has_element?(view, "#group-#{b.id}")

    view |> element("#library-picker-#{lp2.id}") |> render_click()

    assert has_element?(view, "#group-#{b.id}")
    refute has_element?(view, "#group-#{a.id}")
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

    a = seed_group(lp1, cluster_key: "a", display_title: "Library A Group")
    b = seed_group(lp2, cluster_key: "b", display_title: "Library B Group")

    {:ok, view, _html} = live(conn, ~p"/import?type=movies")

    assert has_element?(view, "#group-#{b.id}")
    refute has_element?(view, "#group-#{a.id}")
    assert has_element?(view, "#library-picker-#{lp2.id}.btn-primary")
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

    a = seed_group(lp1, cluster_key: "a", display_title: "Library A Group")
    b = seed_group(lp2, cluster_key: "b", display_title: "Library B Group")

    {:ok, view, _html} = live(conn, ~p"/import?type=tv")

    assert has_element?(view, "#group-#{b.id}")
    refute has_element?(view, "#group-#{a.id}")
    assert has_element?(view, "#library-picker-#{lp2.id}.btn-primary")
  end

  test "the page issues no query on the disconnected render", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})
    seed_group(lp, cluster_key: "a")

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
    ready = seed_group(lp, cluster_key: "ready", min_confidence: 1.0)
    attention = seed_group(lp, cluster_key: "attention", min_confidence: 0.7, file_count: 9)

    attention_file =
      orphaned_media_file_fixture(%{
        library_path_id: lp.id,
        relative_path: "Attention Show/Season 01/a.mkv"
      })

    Repo.update_all(
      from(f in Mydia.Library.MediaFile, where: f.id == ^attention_file.id),
      set: [import_group_id: attention.id]
    )

    {:ok, view, _html} = live(conn, ~p"/import")

    assert has_element?(view, "#group-toggle-#{ready.id} .hero-chevron-right")
    assert has_element?(view, "#group-toggle-#{attention.id} .hero-chevron-down")

    # The attention group is visually open (chevron-down, asserted above),
    # but the page is bounded to loading members for only one group at a
    # time -- the one most recently clicked. Auto-expanding it on load must
    # not eagerly load its members, or the whole point of the bound is lost.
    refute has_element?(view, "#member-row-#{attention_file.id}")
  end

  test "changing the search resets the selection", %{conn: conn} do
    # Regression: select_library and select_band both reset the selection
    # because a selection made under one scope must not leak into another --
    # in :filter mode select_all_matching/1 captures the current :q, so a
    # stale selection would make SelectionScope.selected?/2 mark newly listed
    # rows as checked and accept_selected/ignore_selected would act on
    # groups the search has already narrowed past. "search" had no such
    # reset.
    lp = library_path_fixture(%{type: "series"})
    group = seed_group(lp, cluster_key: "search-reset")
    seed_members(group, lp, 1)

    {:ok, view, _html} = live(conn, ~p"/import")

    render_click(view, "toggle_group", %{"id" => group.id})
    assert has_element?(view, "#bulk-bar", "1 group(s) selected")

    render_change(view, "search", %{"q" => "something else"})

    assert has_element?(view, "#bulk-bar", "0 group(s) selected")
  end

  test "a burst of import_groups_changed broadcasts coalesces into one deferred refresh",
       %{conn: conn} do
    # ApplyImportGroups.broadcast/1 fires once per Oban job, and an active
    # run can complete many jobs in quick succession -- each one otherwise
    # re-triggering refresh_counts/1's full band_counts/1 read on every open
    # page. Prove the fix black-box: two broadcasts arriving back to back
    # must not update the counts until the debounce window elapses, and must
    # then reflect state exactly once, not twice.
    lp = library_path_fixture(%{type: "series"})
    seed_group(lp, cluster_key: "initial")

    {:ok, view, _html} = live(conn, ~p"/import")

    assert has_element?(view, "#band-all .badge", "1")

    seed_group(lp, cluster_key: "second")

    send(view.pid, {:import_groups_changed, lp.id})
    send(view.pid, {:import_groups_changed, lp.id})

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
    seed_group(lp, cluster_key: "a")
    seed_group(lp, cluster_key: "b")

    {:ok, view, _html} = live(conn, ~p"/import")

    assert has_element?(view, "#nav-import-badge", "2")
  end

  # `accept_selected`, `ignore_selected` and `create_local_show` all write to
  # the library (flip a group's status, link a file, or create a MediaItem),
  # same as `start_run`/`stop_run` on this same LiveView -- but, unlike those
  # two, shipped with no authorization guard at all. `/import` sits behind
  # `:require_authenticated` only, not a role check, so a readonly or guest
  # account could reach any of them. This mirrors the dedicated readonly
  # coverage the deleted ReviewMediaLive had for its equivalent handlers
  # (`test/mydia_web/live/review_media_live_test.exs`, removed alongside the
  # module by this branch with nothing put back in its place).
  test "readonly users cannot accept selected groups", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})
    group = seed_group(lp, cluster_key: "readonly-accept", min_confidence: 1.0)
    seed_members(group, lp, 1)

    readonly_conn = log_in_user(conn, user_fixture(%{role: "readonly"}))

    {:ok, view, _html} = live(readonly_conn, ~p"/import")

    render_click(view, "toggle_group", %{"id" => group.id})
    render_click(view, "accept_selected", %{})

    assert Repo.reload!(group).status == "pending"
  end

  test "readonly users cannot ignore selected groups", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})
    group = seed_group(lp, cluster_key: "readonly-ignore")
    seed_members(group, lp, 1)

    readonly_conn = log_in_user(conn, user_fixture(%{role: "readonly"}))

    {:ok, view, _html} = live(readonly_conn, ~p"/import")

    render_click(view, "toggle_group", %{"id" => group.id})
    render_click(view, "ignore_selected", %{})

    assert Repo.reload!(group).status == "pending"
  end

  test "readonly users cannot create a local show from a no-match folder", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})

    group =
      seed_group(lp,
        cluster_key: "readonly-local",
        display_title: "Readonly Show (2023)",
        file_count: 1,
        unresolved_count: 1,
        provider_id: nil,
        min_confidence: nil
      )

    file =
      orphaned_media_file_fixture(%{
        library_path_id: lp.id,
        relative_path: "Readonly Show (2023)/Season 01/ep1.mkv"
      })

    Repo.update_all(from(f in Mydia.Library.MediaFile, where: f.id == ^file.id),
      set: [import_group_id: group.id]
    )

    %Mydia.Library.MatchCandidate{}
    |> Mydia.Library.MatchCandidate.changeset(%{
      media_file_id: file.id,
      rank: 0,
      parsed_info: %{"season" => 1, "episodes" => [1]}
    })
    |> Repo.insert!()

    readonly_conn = log_in_user(conn, user_fixture(%{role: "readonly"}))

    {:ok, view, _html} = live(readonly_conn, ~p"/import")

    render_click(view, "create_local_show", %{"id" => group.id})

    assert Repo.aggregate(Mydia.Media.MediaItem, :count) == 0
    refute Repo.reload!(file).episode_id
    assert Repo.reload!(group).provider_type != "local"
  end

  test "readonly users cannot restore selected ignored groups", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})
    group = seed_group(lp, cluster_key: "readonly-restore", status: "ignored")

    readonly_conn = log_in_user(conn, user_fixture(%{role: "readonly"}))
    {:ok, view, _html} = live(readonly_conn, ~p"/import")

    render_click(view, "select_band", %{"band" => "ignored"})
    render_click(view, "toggle_group", %{"id" => group.id})
    render_click(view, "restore_selected", %{})

    assert Repo.reload!(group).status == "ignored"
  end

  test "readonly users cannot batch rematch", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})
    group = seed_group(lp, cluster_key: "readonly-batch-rematch", provider_id: nil)

    readonly_conn = log_in_user(conn, user_fixture(%{role: "readonly"}))
    {:ok, view, _html} = live(readonly_conn, ~p"/import")

    render_click(view, "toggle_group", %{"id" => group.id})
    render_click(view, "rematch_selected", %{})

    assert Repo.reload!(group).provider_id == nil
  end

  describe "Change match" do
    defp seed_wrong_match(lp) do
      group =
        seed_group(lp,
          cluster_key: "patamuse",
          display_title: "Patamuse (2018)",
          provider_id: "9999",
          provider_type: "tvdb",
          suggested_title: "The Peter Potamus Show",
          suggested_year: 1964,
          min_confidence: 0.703
        )

      file =
        orphaned_media_file_fixture(%{
          library_path_id: lp.id,
          relative_path: "Patamuse (2018)/Season 01/ep1.mkv"
        })

      %Mydia.Library.MatchCandidate{}
      |> Mydia.Library.MatchCandidate.changeset(%{
        media_file_id: file.id,
        rank: 0,
        provider_id: "9999",
        provider_type: "tvdb",
        title: "The Peter Potamus Show",
        confidence: 0.703,
        parsed_info: %{"season" => 1, "episodes" => [1]}
      })
      |> Repo.insert!()

      Repo.update_all(from(f in Mydia.Library.MediaFile, where: f.id == ^file.id),
        set: [import_group_id: group.id]
      )

      {group, file}
    end

    test "the button reads Change match on a matched group and Identify on a no-match one",
         %{conn: conn} do
      lp = library_path_fixture(%{type: "series"})
      {matched, _file} = seed_wrong_match(lp)
      no_match = seed_group(lp, cluster_key: "no-match", provider_id: nil, min_confidence: nil)

      {:ok, view, _html} = live(conn, ~p"/import")

      assert has_element?(view, "#change-match-#{matched.id}", "Change match")
      assert has_element?(view, "#change-match-#{no_match.id}", "Identify")
    end

    test "opens prefilled with the group's suggested title and shows relay results",
         %{conn: conn} do
      lp = library_path_fixture(%{type: "series"})
      {group, _file} = seed_wrong_match(lp)

      {:ok, view, _html} = live(conn, ~p"/import")

      view |> element("#change-match-#{group.id}") |> render_click()
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
      {group, file} = seed_wrong_match(lp)
      series_id = MetadataStubProvider.series_tvdb_id()
      series_title = MetadataStubProvider.series_title()

      {:ok, view, _html} = live(conn, ~p"/import")

      view |> element("#change-match-#{group.id}") |> render_click()
      render_async(view)

      view |> element("#match-result-#{series_id}-tvdb") |> render_click()

      assert has_element?(view, "#flash-info", "Updated the match")
      refute has_element?(view, "#match-results")

      # The group's row re-renders as :ready once the correction lands --
      # a human's pick is at least as trustworthy as an automatic match.
      assert has_element?(view, "#group-#{group.id} .badge-success")

      reloaded_group = Repo.reload!(group)
      assert reloaded_group.provider_id == to_string(series_id)
      assert reloaded_group.provider_type == "tvdb"
      assert reloaded_group.suggested_title == series_title

      candidate = Repo.get_by!(Mydia.Library.MatchCandidate, media_file_id: file.id, rank: 0)
      assert candidate.provider_id == to_string(series_id)
      assert candidate.title == series_title
      assert candidate.parsed_info == %{"season" => 1, "episodes" => [1]}
    end

    test "selecting a result for a group that vanished mid-review flashes instead of crashing",
         %{conn: conn} do
      # The render-then-click race this project has already fixed elsewhere
      # (open_match_search/2 uses the same nil-safe Repo.get/2): another
      # session or a concurrent run removes the group between opening the
      # modal and picking a result. ImportGroups.change_match/2 used to call
      # Repo.get!/2, which would raise Ecto.NoResultsError here and take the
      # whole LiveView process down with it.
      lp = library_path_fixture(%{type: "series"})
      {group, _file} = seed_wrong_match(lp)
      series_id = MetadataStubProvider.series_tvdb_id()

      {:ok, view, _html} = live(conn, ~p"/import")

      view |> element("#change-match-#{group.id}") |> render_click()
      render_async(view)

      Repo.delete!(group)

      view |> element("#match-result-#{series_id}-tvdb") |> render_click()

      assert Process.alive?(view.pid)
      assert has_element?(view, "#flash-error", "no longer available")
      refute has_element?(view, "#match-results")
    end

    test "closing without selecting leaves the group untouched", %{conn: conn} do
      lp = library_path_fixture(%{type: "series"})
      {group, _file} = seed_wrong_match(lp)

      {:ok, view, _html} = live(conn, ~p"/import")

      view |> element("#change-match-#{group.id}") |> render_click()
      render_async(view)

      view |> element("#match-search-modal button", "Cancel") |> render_click()

      refute has_element?(view, "#match-results")
      assert Repo.reload!(group).provider_id == "9999"
    end

    test "applying a corrected match removes the row from needs_attention filter", %{conn: conn} do
      lp = library_path_fixture(%{type: "series"})
      {group, _file} = seed_wrong_match(lp)
      series_id = MetadataStubProvider.series_tvdb_id()

      {:ok, view, _html} = live(conn, ~p"/import")

      # Filter to the "needs_attention" band
      view |> element("#band-needs-attention") |> render_click()

      # Verify the group is visible in this band
      assert has_element?(view, "#group-#{group.id}")

      # Open the match search modal and select a result
      view |> element("#change-match-#{group.id}") |> render_click()
      render_async(view)

      view |> element("#match-result-#{series_id}-tvdb") |> render_click()

      # The group's row should no longer be present because it moved to :ready band
      refute has_element?(view, "#group-#{group.id}")
    end
  end

  test "readonly users cannot apply a chosen match", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})
    {group, _file} = seed_wrong_match(lp)

    readonly_conn = log_in_user(conn, user_fixture(%{role: "readonly"}))

    {:ok, view, _html} = live(readonly_conn, ~p"/import")

    view |> element("#change-match-#{group.id}") |> render_click()
    render_async(view)

    series_id = MetadataStubProvider.series_tvdb_id()
    view |> element("#match-result-#{series_id}-tvdb") |> render_click()

    assert Repo.reload!(group).provider_id == "9999"
  end

  describe "the Ignored view" do
    test "the Ignored chip counts ignored groups and the pending chips exclude them",
         %{conn: conn} do
      lp = library_path_fixture(%{type: "series"})
      seed_group(lp, cluster_key: "pending", min_confidence: 1.0)
      seed_group(lp, cluster_key: "ignored-one", status: "ignored")
      seed_group(lp, cluster_key: "ignored-two", status: "ignored")

      {:ok, view, _html} = live(conn, ~p"/import")

      assert has_element?(view, "#band-ignored", "2")
      assert has_element?(view, "#band-all", "1")
      assert has_element?(view, "#band-ready", "1")
    end

    test "selecting the Ignored chip shows ignored groups and hides pending ones",
         %{conn: conn} do
      lp = library_path_fixture(%{type: "series"})
      pending = seed_group(lp, cluster_key: "pending", min_confidence: 1.0)
      ignored = seed_group(lp, cluster_key: "ignored", status: "ignored")

      {:ok, view, _html} = live(conn, ~p"/import")

      assert has_element?(view, "#group-#{pending.id}")
      refute has_element?(view, "#group-#{ignored.id}")

      view |> element("#band-ignored") |> render_click()

      refute has_element?(view, "#group-#{pending.id}")
      assert has_element?(view, "#group-#{ignored.id}")
    end

    test "an ignored row offers Restore instead of the normal group controls",
         %{conn: conn} do
      lp = library_path_fixture(%{type: "series"})
      ignored = seed_group(lp, cluster_key: "ignored", status: "ignored")

      {:ok, view, _html} = live(conn, ~p"/import")
      view |> element("#band-ignored") |> render_click()

      assert has_element?(view, "#restore-#{ignored.id}")
      assert has_element?(view, "#group-#{ignored.id} input[type=checkbox]")
      refute has_element?(view, "#change-match-#{ignored.id}")
      refute has_element?(view, "#create-local-#{ignored.id}")
    end

    test "restoring a group returns it to pending and moves it back off the Ignored view",
         %{conn: conn} do
      lp = library_path_fixture(%{type: "series"})
      ignored = seed_group(lp, cluster_key: "ignored", status: "ignored")

      {:ok, view, _html} = live(conn, ~p"/import")
      view |> element("#band-ignored") |> render_click()

      view |> element("#restore-#{ignored.id}") |> render_click()

      assert has_element?(view, "#flash-info", "Restored")
      refute has_element?(view, "#group-#{ignored.id}")
      assert Repo.reload!(ignored).status == "pending"
    end

    test "an ignored group accepted then re-viewed as pending shows normal controls again",
         %{conn: conn} do
      lp = library_path_fixture(%{type: "series"})
      group = seed_group(lp, cluster_key: "roundtrip", status: "ignored", min_confidence: 1.0)

      {:ok, view, _html} = live(conn, ~p"/import")
      view |> element("#band-ignored") |> render_click()
      view |> element("#restore-#{group.id}") |> render_click()

      view |> element("#band-all") |> render_click()

      assert has_element?(view, "#group-#{group.id} input[type=checkbox]")
    end
  end

  test "readonly users cannot restore an ignored group", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})
    group = seed_group(lp, cluster_key: "readonly-restore", status: "ignored")

    readonly_conn = log_in_user(conn, user_fixture(%{role: "readonly"}))

    {:ok, view, _html} = live(readonly_conn, ~p"/import")
    view |> element("#band-ignored") |> render_click()

    render_click(view, "restore_group", %{"id" => group.id})

    assert Repo.reload!(group).status == "ignored"
  end

  describe "member episode editing" do
    test "renders filename, folder, matched episode badge, and inline S/E inputs", %{conn: conn} do
      lp = library_path_fixture(%{type: "series"})

      group =
        seed_group(lp, cluster_key: "ep-edit", display_title: "My Show", min_confidence: 1.0)

      file =
        orphaned_media_file_fixture(%{
          library_path_id: lp.id,
          relative_path: "My Show/Season 01/My.Show.S01E03.1080p.mkv"
        })

      %Mydia.Library.MatchCandidate{}
      |> Mydia.Library.MatchCandidate.changeset(%{
        media_file_id: file.id,
        rank: 0,
        provider_type: "tvdb",
        provider_id: "1",
        title: "My Show",
        confidence: 1.0,
        parsed_info: %{"season" => 1, "episodes" => [3]}
      })
      |> Repo.insert!()

      Repo.update_all(from(f in Mydia.Library.MediaFile, where: f.id == ^file.id),
        set: [import_group_id: group.id]
      )

      {:ok, view, _html} = live(conn, ~p"/import")

      view |> element("#group-toggle-#{group.id}") |> render_click()

      assert has_element?(view, "#member-#{file.id}", "My.Show.S01E03.1080p.mkv")
      assert has_element?(view, "#member-row-#{file.id}", "My Show/Season 01")
      assert has_element?(view, "#member-row-#{file.id}", "S01E03")
      assert has_element?(view, "#member-form-#{file.id} input[name=season][value='1']")
      assert has_element?(view, "#member-form-#{file.id} input[name=episode][value='3']")
    end

    test "changing season and episode updates candidate parsed_info and LiveView UI", %{
      conn: conn
    } do
      lp = library_path_fixture(%{type: "series"})

      group =
        seed_group(lp, cluster_key: "ep-change", display_title: "My Show", min_confidence: 1.0)

      file =
        orphaned_media_file_fixture(%{
          library_path_id: lp.id,
          relative_path: "My Show/Season 01/ep.mkv"
        })

      Repo.update_all(from(f in Mydia.Library.MediaFile, where: f.id == ^file.id),
        set: [import_group_id: group.id]
      )

      {:ok, view, _html} = live(conn, ~p"/import")
      view |> element("#group-toggle-#{group.id}") |> render_click()

      assert has_element?(view, "#member-row-#{file.id}", "No episode")

      view
      |> element("#member-form-#{file.id}")
      |> render_change(%{"file_id" => file.id, "season" => "2", "episode" => "8"})

      assert has_element?(view, "#member-row-#{file.id}", "S02E08")

      candidate = Repo.get_by!(Mydia.Library.MatchCandidate, media_file_id: file.id, rank: 0)
      assert candidate.parsed_info["season"] == 2
      assert candidate.parsed_info["episodes"] == [8]
    end

    test "readonly users cannot update member episodes", %{conn: conn} do
      lp = library_path_fixture(%{type: "series"})

      group =
        seed_group(lp, cluster_key: "readonly-ep", display_title: "Show", min_confidence: 1.0)

      file =
        orphaned_media_file_fixture(%{
          library_path_id: lp.id,
          relative_path: "Show/Season 01/a.mkv"
        })

      Repo.update_all(from(f in Mydia.Library.MediaFile, where: f.id == ^file.id),
        set: [import_group_id: group.id]
      )

      readonly_conn = log_in_user(conn, user_fixture(%{role: "readonly"}))
      {:ok, view, _html} = live(readonly_conn, ~p"/import")

      render_change(view, "update_member_episode", %{
        "file_id" => file.id,
        "season" => "1",
        "episode" => "1"
      })

      assert is_nil(Repo.get_by(Mydia.Library.MatchCandidate, media_file_id: file.id, rank: 0))
    end

    test "movie groups do not render season span badges or episode editing forms", %{conn: conn} do
      lp = library_path_fixture(%{type: "movies"})

      group =
        seed_group(lp,
          cluster_key: "movie-1",
          display_title: "Inception",
          media_type: "movie",
          min_confidence: 1.0
        )

      file =
        orphaned_media_file_fixture(%{
          library_path_id: lp.id,
          relative_path: "Inception (2010)/Inception.2010.1080p.mkv"
        })

      Repo.update_all(from(f in Mydia.Library.MediaFile, where: f.id == ^file.id),
        set: [import_group_id: group.id]
      )

      {:ok, view, _html} = live(conn, ~p"/import")
      view |> element("#group-toggle-#{group.id}") |> render_click()

      assert has_element?(view, "#member-#{file.id}", "Inception.2010.1080p.mkv")
      refute has_element?(view, "#member-form-#{file.id}")
      refute has_element?(view, "#member-row-#{file.id}", "No episode")
      refute has_element?(view, "#group-toggle-#{group.id}", "S1")
    end
  end

  describe "batch actions" do
    test "select page selects all visible groups on current page", %{conn: conn} do
      lp = library_path_fixture(%{type: "series"})
      g1 = seed_group(lp, cluster_key: "g1", display_title: "Show 1")
      g2 = seed_group(lp, cluster_key: "g2", display_title: "Show 2")

      {:ok, view, _html} = live(conn, ~p"/import")

      render_click(view, "select_band", %{"band" => "all"})
      # Clicking select current page
      render_click(view, "select_current_page", %{})

      assert has_element?(view, "#bulk-bar", "2 group(s) selected")
      assert has_element?(view, "#group-#{g1.id} input[type=checkbox]:checked")
      assert has_element?(view, "#group-#{g2.id} input[type=checkbox]:checked")
    end

    test "ignored view supports selection, select-all, and batch restore", %{conn: conn} do
      lp = library_path_fixture(%{type: "series"})
      g1 = seed_group(lp, cluster_key: "ig1", display_title: "Ignored 1", status: "ignored")
      g2 = seed_group(lp, cluster_key: "ig2", display_title: "Ignored 2", status: "ignored")

      {:ok, view, _html} = live(conn, ~p"/import")

      render_click(view, "select_band", %{"band" => "ignored"})

      assert has_element?(view, "#restore-#{g1.id}")
      assert has_element?(view, "#restore-#{g2.id}")

      # Toggle individual ignored group
      render_click(view, "toggle_group", %{"id" => g1.id})
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
      assert Repo.reload!(g1).status == "pending"
      assert Repo.reload!(g2).status == "pending"
    end

    test "local show creation is available per row, not as a batch action", %{conn: conn} do
      lp = library_path_fixture(%{type: "series", path: "/media/Series"})

      g1 =
        seed_group(lp,
          cluster_key: "no-match-1",
          display_title: "Custom Show One (2020)",
          provider_id: nil,
          min_confidence: nil
        )

      {:ok, view, _html} = live(conn, ~p"/import")

      render_click(view, "select_band", %{"band" => "no_match"})
      render_click(view, "toggle_group", %{"id" => g1.id})

      refute has_element?(view, "#create-local-selected")
      assert has_element?(view, "#create-local-#{g1.id}", "Create show from folder")
    end

    test "batch rematch re-runs matcher on selected groups", %{conn: conn} do
      lp = library_path_fixture(%{type: "series", path: "/media/Series"})

      g1 =
        seed_group(lp,
          cluster_key: "rematch-1",
          display_title: "Doctor Who (2005)",
          provider_id: nil,
          min_confidence: nil
        )

      file =
        orphaned_media_file_fixture(%{
          library_path_id: lp.id,
          relative_path: "Doctor Who (2005)/Season 01/Doctor Who - S01E01.mkv"
        })

      %Mydia.Library.MatchCandidate{}
      |> Mydia.Library.MatchCandidate.changeset(%{
        media_file_id: file.id,
        rank: 0,
        last_error: "no_match"
      })
      |> Repo.insert!()

      Repo.update_all(from(f in Mydia.Library.MediaFile, where: f.id == ^file.id),
        set: [import_group_id: g1.id]
      )

      {:ok, view, _html} = live(conn, ~p"/import")

      render_click(view, "toggle_group", %{"id" => g1.id})
      assert has_element?(view, "#rematch-selected")

      render_click(view, "rematch_selected", %{})

      assert render(view) =~ "Re-matched 1 group(s)."
    end
  end
end
