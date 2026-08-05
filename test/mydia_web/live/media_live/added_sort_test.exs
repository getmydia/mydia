defmodule MydiaWeb.MediaLive.AddedSortTest do
  # async: false — the Postgres non-shared sandbox hides these rows from the
  # LiveView mount process otherwise.
  use MydiaWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.AccountsFixtures
  import MydiaWeb.AuthHelpers

  setup %{conn: conn} do
    %{conn: log_in_user(conn, admin_user_fixture())}
  end

  test "sorts shows by newest episode arrival, not by show creation", %{conn: conn} do
    stale = media_item_fixture(%{type: "tv_show", title: "Stale Show"})
    stale_ep = episode_fixture(%{media_item_id: stale.id})
    backdate_media_file(media_file_fixture(%{episode_id: stale_ep.id}), ~U[2024-01-01 00:00:00Z])

    fresh = media_item_fixture(%{type: "tv_show", title: "Fresh Show"})
    fresh_ep = episode_fixture(%{media_item_id: fresh.id})
    backdate_media_file(media_file_fixture(%{episode_id: fresh_ep.id}), ~U[2026-08-03 00:00:00Z])

    # Make the *records* the opposite order, so a passing test cannot be
    # explained by media_items.inserted_at.
    Mydia.Repo.update_all(
      from(m in Mydia.Media.MediaItem, where: m.id == ^fresh.id),
      set: [inserted_at: ~U[2023-01-01 00:00:00Z]]
    )

    {:ok, view, _html} = live(conn, ~p"/tv")

    # The sort select lives in the filter form (index.html.heex:119), which
    # fires phx-change="filter".
    html =
      view
      |> element("#library-filter-form")
      |> render_change(%{"sort_by" => "added_desc"})

    # Stream children are keyed `media_items-<item id>` by `stream/3`, and
    # exist in both grid and list view modes.
    fresh_marker = "media_items-#{fresh.id}"
    stale_marker = "media_items-#{stale.id}"

    assert html =~ fresh_marker
    assert html =~ stale_marker

    {fresh_position, _} = :binary.match(html, fresh_marker)
    {stale_position, _} = :binary.match(html, stale_marker)

    assert fresh_position < stale_position
  end

  test "a fileless wanted item sorts by its own inserted_at, not a missing content timestamp",
       %{conn: conn} do
    fresh = media_item_fixture(%{type: "tv_show", title: "Fresh Show"})
    fresh_ep = episode_fixture(%{media_item_id: fresh.id})
    backdate_media_file(media_file_fixture(%{episode_id: fresh_ep.id}), ~U[2026-08-03 00:00:00Z])

    stale = media_item_fixture(%{type: "tv_show", title: "Stale Show"})
    stale_ep = episode_fixture(%{media_item_id: stale.id})
    backdate_media_file(media_file_fixture(%{episode_id: stale_ep.id}), ~U[2024-01-01 00:00:00Z])

    # A wanted item with no files at all has no content_added_at, so its sort
    # key must fall back to its own inserted_at (effective_added_at/2). If
    # that fallback ever regresses from `Map.get` to `Map.fetch!`, this item
    # blows up the whole page instead of just sorting oddly.
    wanted = media_item_fixture(%{type: "tv_show", title: "Wanted Show"})

    Mydia.Repo.update_all(
      from(m in Mydia.Media.MediaItem, where: m.id == ^wanted.id),
      set: [inserted_at: ~U[2025-06-01 00:00:00Z]]
    )

    {:ok, view, _html} = live(conn, ~p"/tv")

    html =
      view
      |> element("#library-filter-form")
      |> render_change(%{"sort_by" => "added_desc"})

    fresh_marker = "media_items-#{fresh.id}"
    wanted_marker = "media_items-#{wanted.id}"
    stale_marker = "media_items-#{stale.id}"

    assert html =~ fresh_marker
    assert html =~ wanted_marker
    assert html =~ stale_marker

    {fresh_position, _} = :binary.match(html, fresh_marker)
    {wanted_position, _} = :binary.match(html, wanted_marker)
    {stale_position, _} = :binary.match(html, stale_marker)

    assert fresh_position < wanted_position
    assert wanted_position < stale_position
  end
end
