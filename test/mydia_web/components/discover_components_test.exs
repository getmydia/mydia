defmodule MydiaWeb.DiscoverComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias MydiaWeb.DiscoverComponents

  defp guest, do: %{role: "guest", id: "guest-1"}

  defp card(assigns_overrides) do
    item =
      Map.merge(
        %{
          provider_id: "693134",
          title: "Dune: Part Two",
          year: 2024,
          poster_path: "/dune.jpg",
          in_library: false,
          monitored: false,
          id: nil,
          request_status: nil
        },
        Map.get(assigns_overrides, :item, %{})
      )

    assigns =
      %{
        item: item,
        media_type: :movie,
        current_user: guest(),
        adding_item_id: nil,
        requesting_item_id: nil,
        libraries: []
      }
      |> Map.merge(Map.delete(assigns_overrides, :item))

    render_component(&DiscoverComponents.trending_card/1, assigns)
  end

  describe "guest request button" do
    test "renders a request_media button rather than a link to the search page" do
      html = card(%{})

      assert html =~ ~s(phx-click="request_media")
      assert html =~ ~s(phx-value-tmdb_id="693134")
      assert html =~ "Request"
      refute html =~ "/request/movie?tmdb_id="
    end

    test "shows the in-flight state while the request is being submitted" do
      html = card(%{requesting_item_id: "693134"})

      assert html =~ "Requesting..."
      assert html =~ "loading-spinner"
      assert html =~ "disabled"
    end

    test "shows a disabled Requested button once a request is outstanding" do
      html = card(%{item: %{request_status: "pending"}})

      assert html =~ "Requested"
      assert html =~ "disabled"
      refute html =~ "Requesting..."
    end

    test "keeps Add to Library for non-guest users" do
      html = card(%{current_user: %{role: "admin", id: "admin-1"}})

      assert html =~ "Add to Library"
      refute html =~ ~s(phx-click="request_media")
    end
  end

  describe "poster loading and size" do
    # Regression: card_poster/1 used to hardcode loading="lazy" and w500 for
    # every caller. A bare trending_card/1 is what the Dashboard and Discover
    # grids render, whose first row is above the fold and must not defer its
    # fetch, so it keeps eager loading at the w500 default.
    test "a bare card carries no loading attribute and the w500 default size" do
      html = card(%{})

      refute html =~ "loading="
      assert html =~ "/w500/dune.jpg"
    end
  end
end
