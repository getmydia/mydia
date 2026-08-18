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

  test "renders one row per group, not one per file", %{conn: conn} do
    lp = library_path_fixture(%{type: "series"})
    a = seed_group(lp, cluster_key: "a", display_title: "Cornemuse", file_count: 65)
    b = seed_group(lp, cluster_key: "b", display_title: "Pin-Pon", file_count: 64)

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
end
