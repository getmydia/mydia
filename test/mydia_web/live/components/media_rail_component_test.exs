defmodule MydiaWeb.Components.MediaRailComponentTest do
  @moduledoc """
  Covers the three poster behaviours the rail needs: a click event on Discover,
  a navigate link for an owned title on the detail page, and an inert poster
  where neither applies. The detail page has no `show_details` handler, so the
  inert case is what keeps a poster click from crashing that LiveView.

  Also covers `:current`, the per-item key the franchise adapter depends on, and
  the shared `adding_ids` set.
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

    document = LazyHTML.from_fragment(html)

    # Poster must not fire show_details; action buttons may still use phx-click.
    refute html =~ ~s(phx-click="show_details")
    assert Enum.count(LazyHTML.query(document, "figure")) == 1
    assert Enum.empty?(LazyHTML.query(document, "figure[phx-click]"))
    assert Enum.empty?(LazyHTML.query(document, "a figure"))
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

    # Regression for #459. Two adds can be in flight at once on the
    # recommendations rail, and the old contract could only name one of them:
    # when the first finished, an arbitrary survivor was chosen and the other
    # still-running card silently lost its spinner.
    test "every id in the set draws a spinner, and nothing else does" do
      html =
        render_component(&DiscoverComponents.media_rail/1,
          items: [
            item(%{provider_id: "201", title: "Busy One"}),
            item(%{provider_id: "202", title: "Busy Two"}),
            item(%{provider_id: "203", title: "Idle"})
          ],
          media_type: :movie,
          current_user: user(),
          adding_ids: MapSet.new(["201", "202"])
        )

      first = extract_item(html, "media-rail", "201")
      second = extract_item(html, "media-rail", "202")
      idle = extract_item(html, "media-rail", "203")

      assert first =~ "loading-spinner"
      assert first =~ "disabled"
      assert second =~ "loading-spinner"
      assert second =~ "disabled"
      refute idle =~ "loading-spinner"
    end

    # The hosts do not agree on id types and cannot be made to. The two detail
    # page sets hold parsed integers because dispatch_add/2 dedupes on the
    # integer and keys start_async with it, while a SearchResult's provider_id
    # is a string. A strict MapSet.member?/2 across that mix would match
    # nothing and draw no spinner, with no compile-time signal.
    test "matches an integer set against string provider ids" do
      html =
        render_component(&DiscoverComponents.media_rail/1,
          items: [
            item(%{provider_id: "201", title: "Busy"}),
            item(%{provider_id: "202", title: "Idle"})
          ],
          media_type: :movie,
          current_user: user(),
          adding_ids: MapSet.new([201])
        )

      assert extract_item(html, "media-rail", "201") =~ "loading-spinner"
      refute extract_item(html, "media-rail", "202") =~ "loading-spinner"
    end

    test "an omitted adding_ids draws no spinners" do
      html =
        render_component(&DiscoverComponents.media_rail/1,
          items: [item(%{provider_id: "201"})],
          media_type: :movie,
          current_user: user()
        )

      refute html =~ "loading-spinner"
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

  defp collapsible(opts) do
    render_component(
      &DiscoverComponents.media_rail/1,
      Keyword.merge(
        [
          items: [item(), item(%{provider_id: "102", title: "Janet Planet"})],
          media_type: :movie,
          current_user: user(),
          collapsible: true,
          toggle_event: "toggle_recommendations"
        ],
        opts
      )
    )
  end

  describe "collapsible rail" do
    test "a collapsed rail renders its header and none of its cards" do
      html = collapsible(expanded: false)

      assert html =~ ~s(id="media-rail-toggle")
      assert html =~ ~s(aria-expanded="false")
      refute html =~ ~s(id="media-rail-items")
      refute html =~ ~s(id="media-rail-item-101")
      refute html =~ "The Eternal Daughter"
    end

    test "an expanded rail renders its cards under the strip id" do
      html = collapsible(expanded: true)

      assert html =~ ~s(aria-expanded="true")
      assert html =~ ~s(id="media-rail-items")
      assert html =~ ~s(id="media-rail-item-101")
      assert html =~ "The Eternal Daughter"
    end

    # aria-controls must name an element that is actually in the document. The
    # strip is removed entirely while collapsed, not hidden, so the attribute has
    # to come and go with it.
    test "aria-controls is present only while the strip is in the document" do
      refute collapsible(expanded: false) =~ "aria-controls"
      assert collapsible(expanded: true) =~ ~s(aria-controls="media-rail-items")
    end

    # `button` takes phrasing content, and a heading is not phrasing content, so
    # the heading has to wrap the button rather than sit inside it.
    test "the disclosure button is nested inside the heading, not the reverse" do
      doc = collapsible(expanded: false) |> LazyHTML.from_fragment()

      assert [_] = Enum.to_list(LazyHTML.query(doc, "h2 > button#media-rail-toggle"))
      assert [] = Enum.to_list(LazyHTML.query(doc, "button h2"))
    end

    test "the header carries the item count" do
      count =
        collapsible(expanded: false)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#media-rail-toggle .badge")
        |> LazyHTML.text()

      assert count == "2"
    end

    test "a non-collapsible rail renders no toggle and no strip id" do
      html =
        render_component(&DiscoverComponents.media_rail/1,
          items: [item()],
          media_type: :movie,
          current_user: user()
        )

      assert html =~ ~s(id="media-rail")
      refute html =~ ~s(id="media-rail-toggle")
      refute html =~ ~s(id="media-rail-items")
      refute html =~ "aria-expanded"
    end

    test "a collapsible rail with no toggle_event raises" do
      assert_raise ArgumentError, ~r/toggle_event/, fn ->
        render_component(&DiscoverComponents.media_rail/1,
          items: [item()],
          media_type: :movie,
          current_user: user(),
          collapsible: true
        )
      end
    end
  end
end
