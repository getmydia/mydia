defmodule MydiaWeb.Live.Components.DetailModalEventsAttrsTest do
  @moduledoc """
  The dialog's primary action is its event contract with the host. Emitting an
  event the host does not handle raises FunctionClauseError and kills the
  LiveView on the very first click, so a host with different handlers must be
  able to say so. `trending_card/1` already carries the same pair for the same
  reason.

  Rendered through render_component/2 rather than a live page: this is about
  which event name lands in the markup, and driving it through a host would add
  a relay warm-up for nothing.
  """

  use MydiaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Mydia.Metadata.Structs.SearchResult
  alias MydiaWeb.Live.Components.TrendingDetailModal

  defp item do
    %SearchResult{
      provider_id: "4242",
      provider: :metadata_relay,
      media_type: :movie,
      title: "Harrow Lane",
      year: 2021
    }
    |> Map.put(:in_library, false)
  end

  defp render_modal(extra) do
    render_component(
      TrendingDetailModal,
      Keyword.merge(
        [
          id: "detail-modal",
          item: item(),
          metadata: nil,
          loading: false,
          current_user: %{role: "admin"},
          open: true,
          libraries: [],
          picker_open: false,
          config_open: false
        ],
        extra
      )
    )
  end

  test "defaults to Discover's event names" do
    html = render_modal([])

    assert html =~ ~s(phx-click="add_to_library")
  end

  test "a host can override the add event" do
    html = render_modal(add_event: "add_selected_item")

    assert html =~ ~s(phx-click="add_selected_item")
    refute html =~ ~s(phx-click="add_to_library")
  end

  test "a host can override the request event" do
    html = render_modal(current_user: %{role: "guest"}, request_event: "request_selected_item")

    assert html =~ ~s(phx-click="request_selected_item")
    refute html =~ ~s(phx-click="request_media")
  end
end
