defmodule MydiaWeb.ImportMediaReviewTest do
  use MydiaWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library.ImportGroup
  alias Mydia.Repo

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

    assert Repo.reload!(group).status == "applied"
    assert Repo.reload!(file).episode_id
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

  test "the nav badge shows the pending group count", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})
    seed_group(lp, cluster_key: "a")
    seed_group(lp, cluster_key: "b")

    {:ok, view, _html} = live(conn, ~p"/import")

    assert has_element?(view, "#nav-import-badge", "2")
  end
end
