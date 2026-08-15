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
    # Regression: PR #461 made loading="lazy" opt-in to protect the LCP element
    # in the first grid row, but that also removed it from every card below the
    # fold, which made the Dashboard's two 20-card grids eagerly fetch roughly
    # 40 w500 posters. Lazy is the safe default; a caller that needs eager
    # loading for an above-the-fold card now opts out with loading={nil}.
    test "a bare card defaults to lazy loading and the w500 poster size" do
      html = card(%{})

      assert html =~ ~s(loading="lazy")
      assert html =~ "/w500/dune.jpg"
    end

    test "loading={nil} opts a card out of lazy loading" do
      html = card(%{loading: nil})

      refute html =~ "loading="
      assert html =~ "/w500/dune.jpg"
    end
  end
end
