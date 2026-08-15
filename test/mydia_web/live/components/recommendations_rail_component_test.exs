defmodule MydiaWeb.Components.RecommendationsRailComponentTest do
  @moduledoc """
  Covers the three poster behaviours the rail needs: a click event on Discover,
  a navigate link for an owned title on the detail page, and an inert poster
  where neither applies. The detail page has no `show_details` handler, so the
  inert case is what keeps a poster click from crashing that LiveView.
  """

  use MydiaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

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
      render_component(&DiscoverComponents.recommendations_rail/1,
        items: [],
        media_type: :movie,
        current_user: user()
      )

    refute html =~ "recommendations-rail"
  end

  test "renders one card per item under the rail id" do
    html =
      render_component(&DiscoverComponents.recommendations_rail/1,
        items: [item(), item(%{provider_id: "102", title: "Janet Planet"})],
        media_type: :movie,
        current_user: user()
      )

    assert html =~ ~s(id="recommendations-rail")
    assert html =~ "The Eternal Daughter"
    assert html =~ "Janet Planet"
  end

  test "an unowned card fires the configured select event" do
    html =
      render_component(&DiscoverComponents.recommendations_rail/1,
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
      render_component(&DiscoverComponents.recommendations_rail/1,
        items: [owned],
        media_type: :movie,
        current_user: user()
      )

    assert html =~ ~s(href="/media/abc-123")
    refute html =~ ~s(phx-click="show_details")
  end

  test "a nil on_select renders an inert poster" do
    html =
      render_component(&DiscoverComponents.recommendations_rail/1,
        items: [item()],
        media_type: :movie,
        current_user: user(),
        on_select: nil
      )

    # Poster must not fire show_details; action buttons may still use phx-click.
    refute html =~ ~s(phx-click="show_details")
    assert html =~ ~s(<figure class="aspect-[2/3] bg-base-300">)
  end
end
