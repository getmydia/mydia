defmodule MydiaWeb.Components.RecentlyAddedRailTest do
  @moduledoc """
  The new-episode badge matters more than it looks: without it, a show already
  in the library reappearing at the front of the rail reads as a bug rather
  than as new episodes arriving.
  """

  use MydiaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Mydia.Media.RecentlyAdded.Entry
  alias MydiaWeb.DashboardLive.Components

  defp entry(attrs) do
    struct(
      Entry,
      Enum.into(attrs, %{
        content_added_at: ~U[2026-08-14 12:00:00Z],
        new_episode_count: nil,
        latest_episode: nil
      })
    )
  end

  defp movie(title) do
    %Mydia.Media.MediaItem{
      id: Ecto.UUID.generate(),
      type: "movie",
      title: title,
      year: 2024,
      metadata: nil
    }
  end

  defp show(title) do
    %{movie(title) | type: "tv_show"}
  end

  test "renders nothing when there are no entries" do
    html = render_component(&Components.recently_added_rail/1, entries: [])

    # Asserts true emptiness rather than the absence of one substring. The
    # requirement is that a fresh install sees no trace of the rail, so a
    # differently-worded empty-state placeholder must fail this too.
    assert String.trim(html) == ""
  end

  test "renders one linked card per entry" do
    movie = movie("Arrival")

    html =
      render_component(&Components.recently_added_rail/1, entries: [entry(%{media_item: movie})])

    assert html =~ "recently-added-rail"
    assert html =~ "Arrival"
    assert html =~ ~s(href="/media/#{movie.id}")
  end

  test "falls back to the placeholder poster when metadata is missing" do
    html =
      render_component(&Components.recently_added_rail/1,
        entries: [entry(%{media_item: movie("Arrival")})]
      )

    assert html =~ "/images/no-poster.svg"
  end

  test "badges a show with its new episode count, pluralized" do
    html =
      render_component(&Components.recently_added_rail/1,
        entries: [entry(%{media_item: show("Severance"), new_episode_count: 2})]
      )

    assert html =~ "2 new episodes"
  end

  test "uses the singular for exactly one new episode" do
    html =
      render_component(&Components.recently_added_rail/1,
        entries: [entry(%{media_item: show("Severance"), new_episode_count: 1})]
      )

    assert html =~ "1 new episode"
    refute html =~ "1 new episodes"
  end

  test "shows no badge for a movie" do
    html =
      render_component(&Components.recently_added_rail/1,
        entries: [entry(%{media_item: movie("Arrival"), new_episode_count: nil})]
      )

    refute html =~ "new episode"
  end
end
