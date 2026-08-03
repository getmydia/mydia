defmodule MydiaWeb.MediaLive.Show.SegmentEvents do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Mydia.Library.SegmentDetection
  alias Mydia.Library.SegmentDetection.Fingerprint
  alias MydiaWeb.Live.Authorization

  @doc """
  Assigns the per-season detection summary the show page renders.

  Availability is a runtime capability check rather than a stored state, so
  installing chromaprint later needs no data repair. While it is missing the
  page shows one note instead of repeating the same status on every season,
  and there is nothing worth querying.
  """
  def assign_segment_status(socket, media_item) do
    available? = Fingerprint.available?()

    socket
    |> assign(:segment_detection_available, available?)
    |> assign(:segment_statuses, season_statuses(media_item, available?))
  end

  @doc """
  Clears a season's detections and returns its files to the pending backlog.

  Cached fingerprints are kept, so the second pass does not re-decode any
  audio. The files land back in the same `pending` state the detection
  scheduler drains, which is what picks the season up again.
  """
  def re_analyze(%{"season-number" => season_number_str}, socket) do
    with :ok <- Authorization.authorize_update_media(socket) do
      season_number = String.to_integer(season_number_str)
      media_item = socket.assigns.media_item

      :ok = SegmentDetection.reset_season(media_item.id, season_number)

      {:noreply,
       socket
       |> assign_segment_status(media_item)
       |> put_flash(:info, "Season #{season_number} queued for segment re-analysis")}
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  defp season_statuses(_media_item, false), do: %{}

  defp season_statuses(%{type: "tv_show"} = media_item, true) do
    media_item.episodes
    |> Enum.map(& &1.season_number)
    |> Enum.uniq()
    |> Map.new(fn season_number ->
      {season_number, SegmentDetection.season_status(media_item.id, season_number)}
    end)
  end

  defp season_statuses(_media_item, true), do: %{}
end
