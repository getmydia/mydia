defmodule MydiaWeb.Components.TrendingDetailModalTest do
  @moduledoc """
  The season badge is the only thing under test here. Movies carry
  number_of_seasons: nil, so the absence case proves the guard rather than a
  media-type branch.
  """

  use MydiaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Mydia.Metadata.Structs.MediaMetadata
  alias Mydia.Metadata.Structs.SearchResult
  alias MydiaWeb.Live.Components.TrendingDetailModal

  # A real %SearchResult{}, not a bare map: Ref.from_search_result/1 (called
  # by item_ref/1 to build the card's phx-value-ref) pattern-matches the
  # struct on purpose, so it can never lack a provider the way a hand-rolled
  # map can. The default is TVDB because a TV show card in this app is
  # predominantly TVDB-sourced (Relay.search/3 routes TV search to TVDB); a
  # movie override always forces :tmdb below, since there is no TVDB movie
  # catalog. No test in this file overrides provider_id or provider directly.
  defp item(attrs \\ %{}) do
    merged =
      Enum.into(attrs, %{
        id: nil,
        provider_id: "101",
        title: "The Quiet Orchard",
        year: 2022,
        poster_path: "/poster.jpg",
        backdrop_path: "/backdrop.jpg",
        overview: "An overview.",
        vote_average: 6.9,
        media_type: :tv_show,
        in_library: false,
        monitored: false
      })

    provider = if merged.media_type == :movie, do: :tmdb, else: :tvdb

    %SearchResult{
      provider_id: merged.provider_id,
      provider: provider,
      media_type: merged.media_type,
      title: merged.title,
      year: merged.year,
      poster_path: merged.poster_path,
      backdrop_path: merged.backdrop_path,
      overview: merged.overview,
      vote_average: merged.vote_average
    }
    |> Map.merge(%{id: merged.id, in_library: merged.in_library, monitored: merged.monitored})
  end

  defp metadata(attrs) do
    struct(MediaMetadata, Enum.into(attrs, %{title: "The Quiet Orchard", year: 2022}))
  end

  # `open: true` is mandatory. The whole modal body sits behind
  # `<%= if @open do %>` (trending_detail_modal.ex:40), so omitting it renders
  # an empty dialog and every assertion below fails for the wrong reason.
  # `rail: []` is an undeclared slot the template calls `render_slot/1` on;
  # without it the render raises KeyError. `config_open` has no default (see
  # the moduledoc) so it must always be passed too.
  defp render_modal(item, metadata, opts \\ []) do
    render_component(TrendingDetailModal,
      id: "trending-detail-modal",
      open: true,
      item: item,
      metadata: metadata,
      loading: false,
      current_user: %{id: Ecto.UUID.generate(), role: "admin", username: "admin"},
      rail: [],
      config_open: Keyword.get(opts, :config_open, false)
    )
  end

  test "renders a pluralized season badge for a show" do
    html = render_modal(item(), metadata(%{number_of_seasons: 3}))

    assert html =~ "3 seasons"
  end

  test "renders a singular season badge for a one-season show" do
    html = render_modal(item(), metadata(%{number_of_seasons: 1}))

    assert html =~ "1 season"
    refute html =~ "1 seasons"
  end

  test "renders no season badge for a movie" do
    html = render_modal(item(%{media_type: :movie}), metadata(%{number_of_seasons: nil}))

    refute html =~ ~r/\d+ seasons?/
  end

  describe "Escape keydown binding" do
    # The configure dialog sits above this modal at z-[1000] and binds its own
    # phx-window-keydown for Escape. phx-window-keydown is not scoped by visual
    # stacking, so without config_open a single Escape press would fire both
    # close_add_config and close_details, silently closing the detail view the
    # user never asked to leave.
    test "binds Escape to close_details when no dialog is open above it" do
      html = render_modal(item(), metadata(%{number_of_seasons: 3}), config_open: false)

      assert LazyHTML.from_fragment(html)
             |> LazyHTML.query(~s(dialog[phx-key="Escape"]))
             |> LazyHTML.attribute("phx-window-keydown") == ["close_details"]
    end

    test "drops the Escape binding while the configure dialog is open" do
      html = render_modal(item(), metadata(%{number_of_seasons: 3}), config_open: true)

      assert LazyHTML.from_fragment(html)
             |> LazyHTML.query(~s(dialog[phx-key="Escape"]))
             |> LazyHTML.attribute("phx-window-keydown") == []
    end
  end

  describe "sticky header layout" do
    test "the modal box is a flex column with a single scrolling child" do
      html = render_modal(item(), metadata(%{number_of_seasons: 1}))

      assert html =~ "flex flex-col"
      assert html =~ ~s(id="trending-detail-modal-body")
      assert html =~ "overflow-y-auto"
    end

    test "the add action lives in the header, not a footer" do
      html = render_modal(item(), metadata(%{number_of_seasons: 1}))

      assert html =~ ~s(id="trending-detail-modal-actions")
      # The deleted footer div was the only element carrying this class pair
      # ("border-t border-base-300 bg-base-100 flex justify-end gap-2", the
      # footer's own styling). Nothing else in the component uses a top
      # border, so this proves the footer markup is gone rather than merely
      # asserting an id that was never on it in the first place.
      refute html =~ "border-t border-base-300"
    end

    test "an owned title offers a link to its page in the header" do
      html = render_modal(item(%{in_library: true, id: "abc"}), metadata(%{}))

      assert html =~ ~s(id="trending-detail-modal-actions")
      assert html =~ "Go to Show"
    end
  end
end
