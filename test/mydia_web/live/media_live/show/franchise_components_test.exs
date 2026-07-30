defmodule MydiaWeb.MediaLive.Show.FranchiseComponentsTest do
  use ExUnit.Case, async: true

  # `render/1` is excluded: our own `render/2` (with its `opts \\ []` default)
  # collides with `Phoenix.LiveViewTest.render/1`, and this suite only ever
  # needs `render_component/2`.
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

  defp render(franchise, opts \\ []) do
    render_component(&FranchiseComponents.franchise_section/1, %{
      franchise: franchise,
      can_add: Keyword.get(opts, :can_add, true),
      adding_tmdb_ids: MapSet.new(Keyword.get(opts, :adding_tmdb_ids, []))
    })
  end

  test "renders the franchise name and the owned count" do
    html =
      render(
        franchise([
          entry(%{tmdb_id: 671, in_library?: true, current?: true, media_item_id: "a"}),
          entry(%{tmdb_id: 672})
        ])
      )

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

  test "the current entry is neither a link nor a button" do
    html =
      render(
        franchise([
          entry(%{tmdb_id: 671, in_library?: true, current?: true, media_item_id: "a"}),
          entry(%{tmdb_id: 672})
        ])
      )

    current = extract_entry(html, 671)
    refute current =~ "<a "
    refute current =~ "<button"
    assert current =~ "ring-primary"
  end

  test "an owned entry links to its media page" do
    html =
      render(
        franchise([
          entry(%{tmdb_id: 671, in_library?: true, current?: true, media_item_id: "a"}),
          entry(%{tmdb_id: 672, in_library?: true, media_item_id: "b7d3"})
        ])
      )

    owned = extract_entry(html, 672)
    assert owned =~ ~s(href="/media/b7d3")
  end

  test "a missing entry is an add button when the user may add" do
    html =
      render(
        franchise([
          entry(%{tmdb_id: 671, in_library?: true, current?: true, media_item_id: "a"}),
          entry(%{tmdb_id: 672})
        ])
      )

    missing = extract_entry(html, 672)
    assert missing =~ ~s(phx-click="add_franchise_movie")
    assert missing =~ ~s(phx-value-tmdb_id="672")
  end

  test "a missing entry is inert without permission" do
    html =
      render(
        franchise([
          entry(%{tmdb_id: 671, in_library?: true, current?: true, media_item_id: "a"}),
          entry(%{tmdb_id: 672})
        ]),
        can_add: false
      )

    missing = extract_entry(html, 672)
    refute missing =~ "phx-click"
    refute missing =~ "<button"
  end

  test "the entry being added shows a spinner and is disabled" do
    html =
      render(
        franchise([
          entry(%{tmdb_id: 671, in_library?: true, current?: true, media_item_id: "a"}),
          entry(%{tmdb_id: 672})
        ]),
        adding_tmdb_ids: [672]
      )

    missing = extract_entry(html, 672)
    assert missing =~ "loading-spinner"
    assert missing =~ "disabled"
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

  test "renders the title and year for each entry" do
    html =
      render(
        franchise([
          entry(%{
            tmdb_id: 671,
            title: "Philosopher's Stone",
            year: 2001,
            in_library?: true,
            current?: true,
            media_item_id: "a"
          }),
          entry(%{tmdb_id: 672, title: "Chamber of Secrets", year: 2002})
        ])
      )

    assert html =~ "Chamber of Secrets"
    assert html =~ "2002"
  end

  # Slices the markup for one entry out of the full section so assertions cannot
  # accidentally match a sibling entry's attributes.
  #
  # `LazyHTML.filter/2` only matches root-level nodes, but the entries are
  # nested inside `#franchise-section`, so it must be `query/2`, which
  # searches descendants (see `index_test.exs` for the same pattern).
  defp extract_entry(html, tmdb_id) do
    doc = LazyHTML.from_fragment(html)

    doc
    |> LazyHTML.query(~s(#franchise-entry-#{tmdb_id}))
    |> LazyHTML.to_html()
  end
end
