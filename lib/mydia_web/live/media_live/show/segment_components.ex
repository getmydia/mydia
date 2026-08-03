defmodule MydiaWeb.MediaLive.Show.SegmentComponents do
  @moduledoc """
  Per-season intro and credits detection status for the show page.

  A compact summary row plus a single action, matching the pattern used by
  download clients and indexers. There is no inline editing: detection either
  worked or it did not, and the remedy is to run it again.

  Lives in its own module because `show/components.ex` is already well past the
  file size guideline.
  """
  use MydiaWeb, :html

  # What a season shows before detection has reported anything for it.
  @empty_status %{state: :pending, files: 0, segments: %{}, sources: []}

  @doc """
  Compact status row for one season's detected segments.
  """
  attr :season_number, :any, required: true
  attr :status, :map, default: nil

  def segment_status_row(assigns) do
    assigns = assign(assigns, :status, assigns.status || @empty_status)

    ~H"""
    <div
      id={"segment-status-season-#{@season_number}"}
      class="flex flex-wrap items-center gap-2 mb-3 text-xs"
    >
      <span class="text-base-content/60">Skip segments</span>

      <span
        id={"segment-state-season-#{@season_number}"}
        class={["badge badge-sm", state_class(@status.state)]}
      >
        {state_label(@status.state)}
      </span>

      <span id={"segment-intro-season-#{@season_number}"} class="text-base-content/60">
        Intro {format_span(@status.segments["intro"], @status.files)}
      </span>

      <span id={"segment-credits-season-#{@season_number}"} class="text-base-content/60">
        Credits {format_span(@status.segments["credits"], @status.files)}
      </span>

      <span :for={source <- @status.sources} class="badge badge-ghost badge-sm">{source}</span>

      <div class="tooltip tooltip-bottom ml-auto" data-tip="Re-analyze skip segments">
        <button
          id={"segment-reanalyze-season-#{@season_number}"}
          type="button"
          class="btn btn-xs btn-ghost"
          phx-click="re_analyze_segments"
          phx-value-season-number={@season_number}
        >
          <.icon name="hero-arrow-path" class="w-3 h-3" /> Re-analyze
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Shown once, in place of the per-season rows, when `fpcalc` is missing.

  Availability is a runtime capability check rather than a stored state, so
  installing chromaprint later needs no data repair: the pending backlog is
  picked up on the next scheduler tick.
  """
  def segment_unavailable_note(assigns) do
    ~H"""
    <div
      id="segment-detection-unavailable"
      class="text-xs text-base-content/60 flex items-center gap-1"
    >
      <.icon name="hero-information-circle" class="w-4 h-4" />
      Detection unavailable: chromaprint not installed
    </div>
    """
  end

  defp state_label(:detected), do: "Detected"
  defp state_label(:partial), do: "Partial"
  defp state_label(:not_found), do: "Not found"
  defp state_label(:failed), do: "Failed"
  defp state_label(_pending), do: "Pending"

  defp state_class(:detected), do: "badge-success"
  defp state_class(:partial), do: "badge-warning"
  defp state_class(:failed), do: "badge-error"
  defp state_class(_other), do: "badge-ghost"

  defp format_span(nil, _total), do: "-"

  defp format_span(%{files: files} = summary, total) when files >= total do
    span(summary)
  end

  # The offsets are medians over the files that carry this type, so a season
  # where only some episodes have one says so rather than implying the whole
  # season shares it.
  defp format_span(summary, total) do
    "#{span(summary)} (#{summary.files} of #{total})"
  end

  defp span(summary) do
    "#{format_ms(summary.start_ms)} to #{format_ms(summary.end_ms)}"
  end

  defp format_ms(ms) do
    total_seconds = div(ms, 1000)
    minutes = div(total_seconds, 60)
    seconds = rem(total_seconds, 60)

    "#{minutes}:#{String.pad_leading(to_string(seconds), 2, "0")}"
  end
end
