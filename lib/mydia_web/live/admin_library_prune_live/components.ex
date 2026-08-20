defmodule MydiaWeb.AdminLibraryPruneLive.Components do
  @moduledoc """
  Function components for the prune review page. Used only by the sibling
  LiveView.
  """

  use MydiaWeb, :html

  alias Mydia.Library.MediaFile

  attr :decision, :map, required: true
  attr :selected, :any, required: true

  def decision_group(assigns) do
    ~H"""
    <div
      class="card bg-base-100 border border-base-300"
      id={"prune-group-#{@decision.group.subject_id}"}
    >
      <div class="card-body gap-3">
        <h3 class="card-title text-base">{subject_label(@decision.group)}</h3>
        <p class="text-sm opacity-70">{@decision.reason}</p>

        <ul class="menu bg-base-200 rounded-box w-full">
          <li :for={file <- [@decision.keeper | @decision.losers]}>
            <div class="flex items-center gap-3">
              <input
                type="radio"
                class="radio radio-sm radio-primary"
                id={"prune-keeper-#{file.id}"}
                name={"keeper-#{@decision.group.subject_id}"}
                checked={file.id == @decision.keeper.id}
                aria-label={"Keep #{file.relative_path}"}
                phx-click="choose_keeper"
                phx-value-subject={@decision.group.subject_id}
                phx-value-file={file.id}
              />
              <span class="flex-1 truncate">{file.relative_path}</span>
              <span class="badge badge-ghost badge-sm">{quality_label(file)}</span>
              <span class="text-xs opacity-60">{humanize_bytes(file.size)}</span>
              <input
                :if={file.id != @decision.keeper.id}
                type="checkbox"
                class="checkbox checkbox-sm checkbox-error"
                id={"prune-loser-#{file.id}"}
                checked={MapSet.member?(@selected, file.id)}
                aria-label={"Trash #{file.relative_path}"}
                phx-click="toggle_loser"
                phx-value-file={file.id}
              />
            </div>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  attr :group, :map, required: true
  attr :reason, :atom, required: true
  attr :detail, :map, required: true

  def refusal_group(assigns) do
    ~H"""
    <div
      class="card bg-base-100 border border-warning/40"
      id={"prune-refusal-#{@group.subject_id}"}
    >
      <div class="card-body gap-2">
        <div class="flex items-center gap-2">
          <.icon name="hero-exclamation-triangle" class="w-4 h-4 text-warning" />
          <h3 class="card-title text-base">{subject_label(@group)}</h3>
          <span class="badge badge-warning badge-sm">{refusal_label(@reason)}</span>
        </div>
        <p class="text-sm opacity-70">{refusal_explanation(@reason, @detail)}</p>
        <ul class="text-xs opacity-60 list-disc pl-5">
          <li :for={file <- @group.files}>{file.relative_path}</li>
        </ul>
      </div>
    </div>
    """
  end

  defp subject_label(%{subject_type: :movie, subject: movie}), do: movie.title

  defp subject_label(%{subject_type: :episode, subject: episode, media_item: show}) do
    "#{show.title} S#{pad(episode.season_number)}E#{pad(episode.episode_number)}"
  end

  defp pad(nil), do: "??"
  defp pad(n), do: String.pad_leading(to_string(n), 2, "0")

  defp quality_label(%MediaFile{} = file) do
    [file.resolution, file.codec] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end

  defp refusal_label(:duplicate_registration), do: "Registered twice"
  defp refusal_label(:unanalyzed), do: "Not analyzed"
  defp refusal_label(:duration_mismatch), do: "Different lengths"
  defp refusal_label(:name_mismatch), do: "Names disagree"
  defp refusal_label(:episode_mismatch), do: "Wrong episode"
  defp refusal_label(:nothing_to_prune), do: "Nothing to prune"

  defp refusal_explanation(:duplicate_registration, detail) do
    "One file on disk is registered twice (#{detail.path}). Trashing a copy would move the only real file. Rescan this library path instead."
  end

  defp refusal_explanation(:unanalyzed, detail) do
    "#{detail.unanalyzed_count} file(s) have no duration, so they cannot be compared. Run analysis first."
  end

  defp refusal_explanation(:duration_mismatch, detail) do
    "These files are #{percent(detail.spread)} apart in length, more than the #{percent(detail.tolerance)} allowed, so they are not the same content. This is usually bonus features or a file matched to the wrong item."
  end

  defp refusal_explanation(:name_mismatch, _detail) do
    "At least one filename does not belong to this item. Fix the match before pruning."
  end

  defp refusal_explanation(:episode_mismatch, _detail) do
    "At least one filename names a different episode than the one it is attached to."
  end

  defp refusal_explanation(:nothing_to_prune, _detail), do: "Only one file remains."

  # Formats a fraction (0.093) as a percentage string ("9.3%") for the
  # duration mismatch explanation.
  defp percent(fraction), do: "#{Float.round(fraction * 100, 1)}%"

  @doc """
  Formats a byte count for display. Public because the page template uses it
  for the running total on the confirm button.
  """
  def humanize_bytes(nil), do: "unknown"

  def humanize_bytes(bytes) when bytes >= 1_073_741_824,
    do: "#{Float.round(bytes / 1_073_741_824, 1)} GB"

  def humanize_bytes(bytes) when bytes >= 1_048_576,
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  def humanize_bytes(bytes), do: "#{bytes} B"
end
