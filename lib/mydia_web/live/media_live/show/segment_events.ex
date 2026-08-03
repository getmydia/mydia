defmodule MydiaWeb.MediaLive.Show.SegmentEvents do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Mydia.Jobs.SegmentDetection, as: SegmentDetectionJob
  alias Mydia.Library.SegmentDetection
  alias Mydia.Library.SegmentDetection.Fingerprint
  alias MydiaWeb.Live.Authorization

  require Logger

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
  audio. The season is enqueued straight away rather than left for the
  scheduler's next tick, because an operator who just clicked the button
  should not wait five minutes to see anything happen.
  """
  def re_analyze(%{"season-number" => season_number_str}, socket) do
    with :ok <- Authorization.authorize_update_media(socket) do
      season_number = String.to_integer(season_number_str)
      media_item = socket.assigns.media_item

      :ok = SegmentDetection.reset_season(media_item.id, season_number)
      enqueue_detection(media_item.id, season_number)

      {:noreply,
       socket
       |> assign_segment_status(media_item)
       |> put_flash(:info, "Season #{season_number} queued for segment re-analysis")}
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  # IMPORTANT: singular Oban.insert/1, never insert_all/1, which silently
  # bypasses the worker's `unique:` option on the Basic and Lite engines this
  # project runs. The scheduler carries the same warning.
  #
  # That uniqueness guard is also why a season the scheduler already queued is
  # not an error here: Oban returns {:ok, job} with `conflict?` set and the
  # existing job stands. The season gets analyzed, which is what was asked for.
  defp enqueue_detection(media_item_id, season_number) do
    %{media_item_id: media_item_id, season_number: season_number}
    |> SegmentDetectionJob.new()
    |> Oban.insert()
    |> case do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        # Not worth alarming the operator over: the files are back in the
        # pending backlog either way, so the scheduler picks the season up on
        # its next tick.
        Logger.warning("Failed to enqueue segment re-analysis",
          media_item_id: media_item_id,
          season_number: season_number,
          reason: inspect(reason)
        )

        :error
    end
  end

  defp season_statuses(_media_item, false), do: %{}

  defp season_statuses(%{type: "tv_show"} = media_item, true),
    do: SegmentDetection.season_statuses(media_item.id)

  defp season_statuses(_media_item, true), do: %{}
end
