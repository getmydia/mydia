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

  defp root_class(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.filter("div.card")
    |> LazyHTML.attribute("class")
    |> List.first()
  end

  defp figure_classes(html) do
    html
    |> LazyHTML.from_fragment()
    # LazyHTML.filter/2 only matches root nodes of the fragment; the figure
    # is nested inside the card div, so it needs query/2 to be found at all.
    |> LazyHTML.query("figure")
    |> LazyHTML.attribute("class")
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

  # Regression for #465. The card root used to carry overflow-hidden, which
  # trapped the absolutely positioned library picker menu inside the card so
  # only its top line was visible. The poster keeps its own clipping instead.
  describe "picker containment" do
    test "the card root does not clip its children" do
      refute root_class(card(%{})) =~ "overflow-hidden"
    end

    test "the card root still draws the ring for the current title" do
      assert root_class(card(%{current: true})) =~ "ring-2"
    end

    # One case per branch of the poster cond: navigate wins first, then
    # on_select (the default), then the inert figure when both are nil.
    test "the poster clips itself in the navigate branch" do
      [class] = figure_classes(card(%{navigate: "/movies/1"}))

      assert class =~ "overflow-hidden"
      assert class =~ "rounded-t-box"
    end

    test "the poster clips itself in the on_select branch" do
      [class] = figure_classes(card(%{}))

      assert class =~ "overflow-hidden"
      assert class =~ "rounded-t-box"
    end

    test "the poster clips itself in the inert branch" do
      [class] = figure_classes(card(%{on_select: nil}))

      assert class =~ "overflow-hidden"
      assert class =~ "rounded-t-box"
    end
  end
end
