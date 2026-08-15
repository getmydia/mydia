defmodule MydiaWeb.MediaLive.Show.FranchiseComponentsTest do
  @moduledoc """
  The franchise strip renders through the shared media rail, so these assertions
  target the rail's markup rather than the bespoke cards this component used to
  draw.
  """

  use MydiaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest, except: [render: 1]

  alias Mydia.Media.{Franchise, FranchiseEntry}
  alias MydiaWeb.MediaLive.Show.FranchiseComponents

  defp entry(attrs) do
    struct!(
      %FranchiseEntry{tmdb_id: 1, title: "Untitled", year: 2001, poster_path: "/p.jpg"},
      attrs
    )
  end

  defp franchise(entries) do
    %Franchise{
      name: "Harry Potter Collection",
      entries: entries,
      owned_count: Enum.count(entries, & &1.in_library?),
      total_count: length(entries)
    }
  end

  defp admin, do: %{id: Ecto.UUID.generate(), role: "admin", username: "admin"}
  defp guest, do: %{id: Ecto.UUID.generate(), role: "guest", username: "g"}

  defp render(franchise, opts \\ []) do
    render_component(&FranchiseComponents.franchise_section/1, %{
      franchise: franchise,
      can_add: Keyword.get(opts, :can_add, true),
      adding_tmdb_ids: MapSet.new(Keyword.get(opts, :adding_tmdb_ids, [])),
      current_user: Keyword.get(opts, :current_user, admin())
    })
  end

  defp two_entries do
    [
      entry(%{tmdb_id: 671, in_library?: true, current?: true, media_item_id: "a"}),
      entry(%{tmdb_id: 672, title: "Chamber of Secrets", year: 2002})
    ]
  end

  test "renders the franchise name and the owned count" do
    html = render(franchise(two_entries()))

    assert html =~ "Harry Potter Collection"
    assert html =~ "1 of 2"
    assert html =~ "badge-ghost"
    refute html =~ "badge-success"
    assert html =~ ~s(id="franchise-section")
  end

  test "marks the count as complete when everything is owned" do
    html =
      render(
        franchise([
          entry(%{tmdb_id: 671, in_library?: true, current?: true, media_item_id: "a"}),
          entry(%{tmdb_id: 672, in_library?: true, media_item_id: "b"})
        ])
      )

    assert html =~ "2 of 2"
    assert html =~ "badge-success"
  end

  test "the current entry draws the ring and offers no action" do
    current = extract_entry(render(franchise(two_entries())), 671)

    assert current =~ "ring-primary"
    refute current =~ "Go to Movie"
    refute current =~ "Add to Library"
    refute current =~ "phx-click"
    refute current =~ "<a "
  end

  test "an owned entry links to its media page" do
    html =
      render(
        franchise([
          entry(%{tmdb_id: 671, in_library?: true, current?: true, media_item_id: "a"}),
          entry(%{tmdb_id: 672, in_library?: true, media_item_id: "b7d3"})
        ])
      )

    assert extract_entry(html, 672) =~ ~s(href="/media/b7d3")
  end

  test "a missing entry offers the franchise add event" do
    missing = extract_entry(render(franchise(two_entries())), 672)

    assert missing =~ ~s(phx-click="add_franchise_movie")
    assert missing =~ ~s(phx-value-tmdb_id="672")
  end

  test "a missing entry is inert without permission" do
    missing = extract_entry(render(franchise(two_entries()), can_add: false), 672)

    refute missing =~ ~s(phx-click="add_franchise_movie")
    refute missing =~ "Add to Library"
    # And specifically not the owned branch's link, which would be built from a
    # nil media_item_id and render href="/movies/".
    refute missing =~ "Go to Movie"
    refute missing =~ ~s(href="/movies/")
  end

  # Regression: the rail renders a Request button for a guest on any unowned
  # card. If it emitted the default "request_media", MediaLive.Show would raise
  # FunctionClauseError on the first click.
  test "a guest gets the franchise request event, not the default" do
    missing = extract_entry(render(franchise(two_entries()), current_user: guest()), 672)

    assert missing =~ ~s(phx-click="request_franchise_movie")
    refute missing =~ ~s(phx-click="request_media")
  end

  test "a guest keeps the request affordance even without add permission" do
    missing =
      extract_entry(
        render(franchise(two_entries()), current_user: guest(), can_add: false),
        672
      )

    assert missing =~ ~s(phx-click="request_franchise_movie")
  end

  test "an already requested entry shows as requested" do
    html =
      render(
        franchise([
          entry(%{tmdb_id: 671, in_library?: true, current?: true, media_item_id: "a"}),
          entry(%{tmdb_id: 672, request_status: "pending"})
        ]),
        current_user: guest()
      )

    assert extract_entry(html, 672) =~ "Requested"
  end

  test "every entry in flight shows a spinner, and only those" do
    html =
      render(
        franchise([
          entry(%{tmdb_id: 671, in_library?: true, current?: true, media_item_id: "a"}),
          entry(%{tmdb_id: 672}),
          entry(%{tmdb_id: 673}),
          entry(%{tmdb_id: 674})
        ]),
        adding_tmdb_ids: [672, 673]
      )

    assert extract_entry(html, 672) =~ "loading-spinner"
    assert extract_entry(html, 673) =~ "loading-spinner"
    refute extract_entry(html, 674) =~ "loading-spinner"
  end

  test "renders a placeholder when a poster is missing" do
    html =
      render(
        franchise([
          entry(%{tmdb_id: 671, in_library?: true, current?: true, media_item_id: "a"}),
          entry(%{tmdb_id: 672, poster_path: nil})
        ])
      )

    missing = extract_entry(html, 672)

    refute missing =~ "<img"
    assert missing =~ "hero-film"
  end

  test "renders the title, year and rating for each entry" do
    html =
      render(
        franchise([
          entry(%{
            tmdb_id: 671,
            title: "Philosopher's Stone",
            in_library?: true,
            current?: true,
            media_item_id: "a"
          }),
          entry(%{tmdb_id: 672, title: "Chamber of Secrets", year: 2002, vote_average: 7.4})
        ])
      )

    missing = extract_entry(html, 672)

    assert missing =~ "Chamber of Secrets"
    assert missing =~ "2002"
    assert missing =~ "7.4"
  end

  # Slices one entry out of the section so an assertion cannot accidentally match
  # a sibling. `LazyHTML.filter/2` only matches root-level nodes and the entries
  # are nested inside #franchise-section, so this must be `query/2`.
  defp extract_entry(html, tmdb_id) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(#franchise-section-item-#{tmdb_id}))
    |> LazyHTML.to_html()
  end
end
