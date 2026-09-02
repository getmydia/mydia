defmodule MydiaWeb.DiscoverComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Mydia.Metadata.Structs.SearchResult
  alias MydiaWeb.DiscoverComponents

  defp guest, do: %{role: "guest", id: "guest-1"}

  # A real %SearchResult{}, not a bare map: Ref.from_search_result/1 (called
  # to build the card's phx-value-ref) pattern-matches the struct on purpose.
  # :tmdb is not a habit-default here -- every card in this file is a movie
  # (media_type: :movie throughout), and there is no TVDB movie catalog, so
  # :tmdb is the only correct provider for it.
  defp card(assigns_overrides) do
    item =
      %SearchResult{
        provider_id: "693134",
        provider: :tmdb,
        media_type: :movie,
        title: "Vertex Horizon",
        year: 2024,
        poster_path: "/vertex.jpg"
      }
      |> Map.merge(%{in_library: false, monitored: false, id: nil, request_status: nil})
      |> Map.merge(Map.get(assigns_overrides, :item, %{}))

    assigns =
      %{
        item: item,
        media_type: :movie,
        current_user: guest(),
        adding_ids: MapSet.new(),
        requesting_item_id: nil
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

  defp rail(overrides) do
    item =
      %SearchResult{
        provider_id: "693134",
        provider: :tmdb,
        media_type: :movie,
        title: "Vertex Horizon",
        year: 2024,
        poster_path: "/vertex.jpg"
      }
      |> Map.merge(%{in_library: false, monitored: false, id: nil, request_status: nil})

    assigns =
      Map.merge(
        %{
          items: [item],
          media_type: :movie,
          current_user: %{role: "admin", id: "admin-1"},
          adding_ids: MapSet.new()
        },
        overrides
      )

    render_component(&DiscoverComponents.media_rail/1, assigns)
  end

  describe "guest request button" do
    test "renders a request_media button rather than a link to the search page" do
      html = card(%{})

      assert html =~ ~s(phx-click="request_media")
      assert html =~ ~s(phx-value-ref="tmdb:693134")
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

    test "offers the add action instead of a request for non-guest users" do
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
      assert html =~ "/w500/vertex.jpg"
    end

    test "loading={nil} opts a card out of lazy loading" do
      html = card(%{loading: nil})

      refute html =~ "loading="
      assert html =~ "/w500/vertex.jpg"
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

  # The rail is a horizontal scroll container (overflow-x-auto, which makes
  # overflow-y compute to auto as well) and is one card tall. That is why the
  # old anchored dropdown was withdrawn here: it could not escape the
  # container at any placement. The picker is now a page-level dialog, which
  # the container cannot clip, so rail cards can target a chosen library
  # again. See #465.
  describe "media_rail configure caret" do
    # The caret no longer gates on `libraries` at all: it opens the merged
    # configure dialog directly, so it renders unconditionally. `libraries`
    # is not even an attr on media_rail/1 or trending_card/1 anymore.
    test "a rail card offers the caret" do
      html = rail(%{})

      assert html =~ "Add to Library"
      assert html =~ "add-config-caret"
    end
  end

  describe "card add button" do
    test "shows the short label while keeping the full accessible name" do
      html = card(%{current_user: %{role: "admin", id: "admin-1"}})

      button =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s(button[phx-click="add_to_library"]))

      # Guard the cardinality first: LazyHTML.attribute/2 silently drops any
      # matched node that lacks the attribute, so a spurious second button
      # missing aria-label would still produce a single-element list below
      # and pass the assertion undetected.
      assert Enum.count(button) == 1
      assert LazyHTML.attribute(button, "aria-label") == ["Add to Library"]
      assert LazyHTML.attribute(button, "title") == ["Add to Library"]

      # The visible label is what wraps at 144px, so assert on rendered text
      # rather than on the raw HTML, which still contains the long string in
      # the aria-label.
      assert button |> LazyHTML.text() |> String.trim() == "Add"
    end

    # Regression: the existing media_rail tests above only assert
    # `html =~ "Add to Library"`, which now passes via the aria-label/title
    # attributes rather than the visible label, so nothing actually verified
    # what a rail card renders on screen. The rail's w-36 (144px) card is the
    # worst-affected case for the wrap, so it gets the same rendered-text
    # assertion as the grid card above.
    test "a rail card shows the short label while keeping the full accessible name" do
      html = rail(%{})

      button =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s(button[phx-click="add_to_library"]))

      assert Enum.count(button) == 1
      assert LazyHTML.attribute(button, "aria-label") == ["Add to Library"]
      assert LazyHTML.attribute(button, "title") == ["Add to Library"]
      assert button |> LazyHTML.text() |> String.trim() == "Add"
    end
  end
end
