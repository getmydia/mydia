defmodule MydiaWeb.Components.TrendingDetailModalTest do
  @moduledoc """
  The season badge is the only thing under test here. Movies carry
  number_of_seasons: nil, so the absence case proves the guard rather than a
  media-type branch.
  """

  use MydiaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Mydia.Metadata.Structs.MediaMetadata
  alias MydiaWeb.Live.Components.TrendingDetailModal

  defp item(attrs \\ %{}) do
    Enum.into(attrs, %{
      id: nil,
      provider_id: "101",
      title: "The Eternal Daughter",
      year: 2022,
      poster_path: "/poster.jpg",
      backdrop_path: "/backdrop.jpg",
      overview: "An overview.",
      vote_average: 6.9,
      media_type: :tv_show,
      in_library: false,
      monitored: false
    })
  end

  defp metadata(attrs) do
    struct(MediaMetadata, Enum.into(attrs, %{title: "The Eternal Daughter", year: 2022}))
  end

  # `open: true` is mandatory. The whole modal body sits behind
  # `<%= if @open do %>` (trending_detail_modal.ex:40), so omitting it renders
  # an empty dialog and every assertion below fails for the wrong reason.
  # `rail: []` is an undeclared slot the template calls `render_slot/1` on;
  # without it the render raises KeyError. `picker_open` has no default (see
  # the moduledoc) so it must always be passed too.
  defp render_modal(item, metadata, opts \\ []) do
    render_component(TrendingDetailModal,
      id: "trending-detail-modal",
      open: true,
      item: item,
      metadata: metadata,
      loading: false,
      current_user: %{id: Ecto.UUID.generate(), role: "admin", username: "admin"},
      libraries: [],
      rail: [],
      picker_open: Keyword.get(opts, :picker_open, false)
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
    # Both this modal and the library picker dialog it can open
    # (MydiaWeb.Components.LibraryComponents.library_picker_dialog/1) bind
    # `phx-window-keydown` with `phx-key="Escape"` as a workaround for
    # `open`-attribute dialogs getting no native Escape handling. That
    # binding attaches per DOM node rather than by visual stacking order, so
    # without `picker_open` a single Escape press would fire both handlers
    # in the same LiveView process and close this modal out from under the
    # picker instead of only the top layer.
    test "binds close_details on Escape when no other dialog is on top" do
      html = render_modal(item(), metadata(%{number_of_seasons: 3}), picker_open: false)
      document = LazyHTML.from_fragment(html)

      dialog = LazyHTML.filter(document, "dialog")

      assert Enum.count(dialog) == 1
      assert LazyHTML.attribute(dialog, "phx-window-keydown") == ["close_details"]
    end

    test "does not bind Escape while the library picker dialog is open" do
      html = render_modal(item(), metadata(%{number_of_seasons: 3}), picker_open: true)
      document = LazyHTML.from_fragment(html)

      dialog = LazyHTML.filter(document, "dialog")

      assert Enum.count(dialog) == 1
      assert LazyHTML.attribute(dialog, "phx-window-keydown") == []
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
      refute html =~ ~s(id="trending-detail-modal-footer")
    end

    test "an owned title offers a link to its page in the header" do
      html = render_modal(item(%{in_library: true, id: "abc"}), metadata(%{}))

      assert html =~ ~s(id="trending-detail-modal-actions")
      assert html =~ "Go to Show"
    end
  end
end
