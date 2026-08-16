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
  # without it the render raises KeyError.
  defp render_modal(item, metadata) do
    render_component(TrendingDetailModal,
      id: "trending-detail-modal",
      open: true,
      item: item,
      metadata: metadata,
      loading: false,
      current_user: %{id: Ecto.UUID.generate(), role: "admin", username: "admin"},
      libraries: [],
      rail: []
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
end
