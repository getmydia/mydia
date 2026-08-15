defmodule MydiaWeb.Components.MediaRailComponentTest do
  @moduledoc """
  Covers the three poster behaviours the rail needs: a click event on Discover,
  a navigate link for an owned title on the detail page, and an inert poster
  where neither applies. The detail page has no `show_details` handler, so the
  inert case is what keeps a poster click from crashing that LiveView.

  Also covers the two per-item keys the franchise adapter depends on, `:current`
  and `:adding`.
  """

  use MydiaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component, only: [sigil_H: 2]

  alias MydiaWeb.DiscoverComponents

  defp item(attrs \\ %{}) do
    Enum.into(attrs, %{
      provider_id: "101",
      title: "The Eternal Daughter",
      year: 2022,
      poster_path: "/poster.jpg",
      vote_average: 6.9,
      in_library: false,
      monitored: false,
      id: nil
    })
  end

  defp user, do: %{id: Ecto.UUID.generate(), role: "admin", username: "admin"}

  test "renders nothing when there are no items" do
    html =
      render_component(&DiscoverComponents.media_rail/1,
        items: [],
        media_type: :movie,
        current_user: user()
      )

    refute html =~ "media-rail"
  end

  test "renders one card per item under the rail id" do
    html =
      render_component(&DiscoverComponents.media_rail/1,
        items: [item(), item(%{provider_id: "102", title: "Janet Planet"})],
        media_type: :movie,
        current_user: user()
      )

    assert html =~ ~s(id="media-rail")
    assert html =~ "The Eternal Daughter"
    assert html =~ "Janet Planet"
  end

  # Regression: card_poster/1 used to hardcode loading="lazy" and w500 for
  # every caller, which regressed LCP on the Dashboard and Discover grids
  # (whose first row is above the fold) and oversized a 144px rail card.
  test "a rail card is lazy-loaded at the w342 size" do
    html =
      render_component(&DiscoverComponents.media_rail/1,
        items: [item()],
        media_type: :movie,
        current_user: user()
      )

    assert html =~ ~s(loading="lazy")
    assert html =~ "/w342/poster.jpg"
  end

  test "an unowned card fires the configured select event" do
    html =
      render_component(&DiscoverComponents.media_rail/1,
        items: [item()],
        media_type: :movie,
        current_user: user(),
        on_select: "show_details"
      )

    assert html =~ ~s(phx-click="show_details")
    assert html =~ ~s(phx-value-id="101")
  end

  test "an owned card with a navigate target renders a link, not a click handler" do
    owned = item(%{in_library: true, id: "abc-123", navigate: "/media/abc-123"})

    html =
      render_component(&DiscoverComponents.media_rail/1,
        items: [owned],
        media_type: :movie,
        current_user: user()
      )

    assert html =~ ~s(href="/media/abc-123")
    refute html =~ ~s(phx-click="show_details")
  end

  test "a nil on_select renders an inert poster" do
    html =
      render_component(&DiscoverComponents.media_rail/1,
        items: [item()],
        media_type: :movie,
        current_user: user(),
        on_select: nil
      )

    # Poster must not fire show_details; action buttons may still use phx-click.
    refute html =~ ~s(phx-click="show_details")
    assert html =~ ~s(<figure class="aspect-[2/3] bg-base-300">)
  end

  describe "action event contract" do
    # Regression: the rail defaults to Discover's events. On a host with
    # different handlers that meant the first click on an unowned card emitted
    # an event nobody handled, which raises FunctionClauseError and kills the
    # LiveView. The host must be able to name its own events.
    test "defaults to the Discover event names" do
      html =
        render_component(&DiscoverComponents.media_rail/1,
          items: [item()],
          media_type: :movie,
          current_user: user()
        )

      assert html =~ ~s(phx-click="add_to_library")
    end

    test "emits the host's add event when overridden" do
      html =
        render_component(&DiscoverComponents.media_rail/1,
          items: [item()],
          media_type: :movie,
          current_user: user(),
          add_event: "add_recommendation"
        )

      assert html =~ ~s(phx-click="add_recommendation")
      refute html =~ ~s(phx-click="add_to_library")
    end

    test "emits the host's request event for a guest" do
      html =
        render_component(&DiscoverComponents.media_rail/1,
          items: [item()],
          media_type: :movie,
          current_user: %{id: Ecto.UUID.generate(), role: "guest", username: "g"},
          request_event: "request_recommendation"
        )

      assert html =~ ~s(phx-click="request_recommendation")
      refute html =~ ~s(phx-click="request_media")
    end

    test "renders no add affordance when the user cannot create media" do
      html =
        render_component(&DiscoverComponents.media_rail/1,
          items: [item()],
          media_type: :movie,
          current_user: user(),
          can_add: false
        )

      refute html =~ "Add to Library"
    end

    test "a guest keeps the request affordance even when can_add is false" do
      html =
        render_component(&DiscoverComponents.media_rail/1,
          items: [item()],
          media_type: :movie,
          current_user: %{id: Ecto.UUID.generate(), role: "guest", username: "g"},
          can_add: false
        )

      assert html =~ ~s(phx-click="request_media")
    end
  end

  describe "per-item keys" do
    test "renders a badge when the slot is filled" do
      assigns = %{
        items: [item()],
        media_type: :movie,
        current_user: user()
      }

      html =
        rendered_to_string(~H"""
        <DiscoverComponents.media_rail
          items={@items}
          media_type={@media_type}
          current_user={@current_user}
        >
          <:badge><span class="badge badge-ghost">1 of 2</span></:badge>
        </DiscoverComponents.media_rail>
        """)

      assert html =~ "1 of 2"
      assert html =~ "badge-ghost"
    end

    test "gives every item a wrapper id derived from the rail id" do
      html =
        render_component(&DiscoverComponents.media_rail/1,
          items: [item(), item(%{provider_id: "102", title: "Janet Planet"})],
          media_type: :movie,
          current_user: user(),
          id: "franchise-section"
        )

      assert html =~ ~s(id="franchise-section-item-101")
      assert html =~ ~s(id="franchise-section-item-102")
    end

    test "a current item draws the ring and renders no action" do
      current = item(%{in_library: true, id: "abc", navigate: nil, current: true})

      html =
        render_component(&DiscoverComponents.media_rail/1,
          items: [current],
          media_type: :movie,
          current_user: user(),
          on_select: nil
        )

      assert html =~ "ring-primary"
      refute html =~ "Go to Movie"
      refute html =~ "Add to Library"
    end

    # `adding_item_id` can only name one in-flight add. The franchise strip
    # routinely has several, so an item may carry its own flag.
    test "an item's own adding flag beats the single adding_item_id" do
      html =
        render_component(&DiscoverComponents.media_rail/1,
          items: [
            item(%{provider_id: "201", title: "Busy", adding: true}),
            item(%{provider_id: "202", title: "Idle", adding: false})
          ],
          media_type: :movie,
          current_user: user()
        )

      busy = extract_item(html, "media-rail", "201")
      idle = extract_item(html, "media-rail", "202")

      assert busy =~ "loading-spinner"
      assert busy =~ "disabled"
      refute idle =~ "loading-spinner"
    end

    test "falls back to adding_item_id when an item carries no flag" do
      html =
        render_component(&DiscoverComponents.media_rail/1,
          items: [item(%{provider_id: "301"}), item(%{provider_id: "302"})],
          media_type: :movie,
          current_user: user(),
          adding_item_id: "301"
        )

      assert extract_item(html, "media-rail", "301") =~ "loading-spinner"
      refute extract_item(html, "media-rail", "302") =~ "loading-spinner"
    end

    # Regression: an unowned card for a user who may neither add nor request
    # used to fall through to a Go to Movie link built from a nil id, rendering
    # href="/movies/". It must render no action at all.
    test "an unowned card renders no action when the user may not add" do
      html =
        render_component(&DiscoverComponents.media_rail/1,
          items: [item()],
          media_type: :movie,
          current_user: user(),
          can_add: false
        )

      refute html =~ "Add to Library"
      refute html =~ "Go to Movie"
      refute html =~ ~s(href="/movies/")
    end
  end

  # Slices one item's markup out of the rail so an assertion cannot accidentally
  # match a sibling. `LazyHTML.filter/2` only matches root-level nodes and the
  # items are nested, so this must be `query/2`.
  defp extract_item(html, rail_id, provider_id) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(##{rail_id}-item-#{provider_id}))
    |> LazyHTML.to_html()
  end
end
