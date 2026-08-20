defmodule MydiaWeb.AdminLibraryPruneLive.Components do
  @moduledoc """
  Function components for the prune review page. Used only by the sibling
  LiveView.
  """

  use MydiaWeb, :html

  alias Mydia.Library.MediaFile

  @doc """
  Renders the Prune Duplicates tab content.
  """
  attr :decisions, :list, required: true
  attr :refusals, :list, required: true
  attr :selected, :any, required: true
  attr :reclaimable, :integer, required: true
  attr :retention_days, :integer, required: true

  def prune_tab(assigns) do
    total_losers =
      Enum.reduce(assigns.decisions, 0, fn decision, acc -> acc + length(decision.losers) end)

    assigns = assign(assigns, :all_selected?, MapSet.size(assigns.selected) == total_losers)

    ~H"""
    <div class="p-4 sm:p-6 space-y-4">
      <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
        <h2 class="text-lg font-semibold flex items-center gap-2">
          <.icon name="hero-document-duplicate" class="w-5 h-5 opacity-60" /> Duplicate Files
          <span class="badge badge-ghost">{length(@decisions)}</span>
        </h2>
        <div class="join">
          <button
            :if={not @all_selected?}
            id="prune-select-all"
            type="button"
            class="btn btn-sm btn-ghost join-item"
            phx-click="select_all_prune_files"
          >
            <.icon name="hero-check-circle" class="w-4 h-4" /> Select all
          </button>
          <button
            id="prune-trash-selected"
            type="button"
            class="btn btn-sm btn-error join-item"
            disabled={MapSet.size(@selected) == 0}
            phx-click="open_prune_modal"
          >
            <.icon name="hero-trash" class="w-4 h-4" />
            Trash {file_count(MapSet.size(@selected))} ({humanize_bytes(@reclaimable)})
          </button>
        </div>
      </div>

      <p class="text-sm text-base-content/60">
        Items holding more than one file, where every copy is proven to be the same content.
        The lower-quality copies are already selected, so one click on Trash clears them all.
        The radio marks the file that stays. Trashed files are kept for {@retention_days} days before permanent deletion.
      </p>

      <%= if @decisions == [] do %>
        <div class="alert alert-info">
          <.icon name="hero-information-circle" class="w-5 h-5" />
          <span :if={@refusals == []}>
            No item holds more than one file. There is nothing to prune.
          </span>
          <span :if={@refusals != []}>
            Nothing can be pruned safely right now. Every item below needs attention first.
          </span>
        </div>
      <% else %>
        <div class="bg-base-200 rounded-box divide-y divide-base-300">
          <.decision_row :for={decision <- @decisions} decision={decision} selected={@selected} />
        </div>
      <% end %>

      <%= if @refusals != [] do %>
        <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3 pt-2">
          <h2 class="text-lg font-semibold flex items-center gap-2">
            <.icon name="hero-exclamation-triangle" class="w-5 h-5 opacity-60" /> Needs Attention
            <span class="badge badge-ghost">{length(@refusals)}</span>
          </h2>
        </div>

        <p class="text-sm text-base-content/60">
          These were not pruned. Each one is a matching or scanning problem rather than a
          duplicate, and acting on them would remove real media.
        </p>

        <div class="bg-base-200 rounded-box divide-y divide-base-300">
          <.refusal_row
            :for={{group, reason, detail} <- @refusals}
            group={group}
            reason={reason}
            detail={detail}
          />
        </div>
      <% end %>
    </div>
    """
  end

  attr :decision, :map, required: true
  attr :selected, :any, required: true

  defp decision_row(assigns) do
    selected_count = Enum.count(assigns.decision.losers, &MapSet.member?(assigns.selected, &1.id))

    assigns = assign(assigns, :selected_count, selected_count)

    ~H"""
    <div class="p-3 sm:p-4" id={"prune-group-#{@decision.group.subject_id}"}>
      <div class="flex items-center gap-3">
        <div class="flex-1 min-w-0">
          <div class="font-medium truncate">{subject_label(@decision.group)}</div>
          <div class="text-xs opacity-60 truncate">{@decision.reason}</div>
        </div>

        <span class="badge badge-sm badge-outline hidden sm:inline-flex">
          {file_count(length(@decision.losers) + 1)}
        </span>
        <span :if={@selected_count > 0} class="badge badge-sm badge-outline badge-error">
          {@selected_count} to trash
        </span>
        <span :if={@selected_count == 0} class="badge badge-sm badge-outline">Skipped</span>

        <div class="join ml-auto sm:ml-2">
          <button
            id={"prune-group-toggle-#{@decision.group.subject_id}"}
            type="button"
            class="btn btn-sm btn-ghost join-item"
            title={
              if @selected_count > 0,
                do: "Keep every file in this group",
                else: "Trash every duplicate in this group"
            }
            aria-label={
              if @selected_count > 0,
                do: "Keep every file in #{subject_label(@decision.group)}",
                else: "Trash every duplicate in #{subject_label(@decision.group)}"
            }
            phx-click="toggle_prune_group"
            phx-value-subject={@decision.group.subject_id}
          >
            <.icon
              name={if @selected_count > 0, do: "hero-x-mark", else: "hero-check"}
              class="w-4 h-4"
            />
          </button>
        </div>
      </div>

      <div class="bg-base-100 rounded-box divide-y divide-base-300 mt-3">
        <div
          :for={file <- [@decision.keeper | @decision.losers]}
          class="flex items-center gap-3 px-3 py-2"
        >
          <input
            type="radio"
            class="radio radio-sm radio-primary shrink-0"
            id={"prune-keeper-#{file.id}"}
            name={"keeper-#{@decision.group.subject_id}"}
            checked={file.id == @decision.keeper.id}
            aria-label={"Keep #{file.relative_path}"}
            phx-click="choose_prune_keeper"
            phx-value-subject={@decision.group.subject_id}
            phx-value-file={file.id}
          />
          <span class="flex-1 min-w-0 truncate text-sm">{file.relative_path}</span>
          <span class="badge badge-ghost badge-sm">{quality_label(file)}</span>
          <span class="text-xs opacity-60 whitespace-nowrap">{humanize_bytes(file.size)}</span>
          <div class="w-5 flex justify-end shrink-0">
            <input
              :if={file.id != @decision.keeper.id}
              type="checkbox"
              class="checkbox checkbox-sm checkbox-error"
              id={"prune-loser-#{file.id}"}
              checked={MapSet.member?(@selected, file.id)}
              aria-label={"Trash #{file.relative_path}"}
              phx-click="toggle_prune_file"
              phx-value-file={file.id}
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :group, :map, required: true
  attr :reason, :atom, required: true
  attr :detail, :map, required: true

  defp refusal_row(assigns) do
    ~H"""
    <div class="p-3 sm:p-4" id={"prune-refusal-#{@group.subject_id}"}>
      <div class="flex items-center gap-3">
        <div class="flex-1 min-w-0">
          <div class="font-medium truncate">{subject_label(@group)}</div>
          <div class="text-xs opacity-60 truncate">{file_count(length(@group.files))}</div>
        </div>
        <span class="badge badge-sm badge-outline badge-warning">{refusal_label(@reason)}</span>
      </div>

      <p class="text-sm text-base-content/60 mt-2">{refusal_explanation(@reason, @detail)}</p>

      <ul class="text-xs opacity-60 list-disc pl-5 mt-1">
        <li :for={file <- @group.files}>{file.relative_path}</li>
      </ul>
    </div>
    """
  end

  @doc """
  Renders the trash confirmation modal.

  A `data-confirm` would be enough for a single row, but this button moves
  every selected duplicate across the whole library in one go. The blast
  radius (files, items, bytes) is worth showing before it runs.
  """
  attr :count, :integer, required: true
  attr :items, :integer, required: true
  attr :bytes, :integer, required: true
  attr :retention_days, :integer, required: true

  def prune_confirm_modal(assigns) do
    ~H"""
    <div id="prune-confirm-modal" class="modal modal-open">
      <div class="modal-box">
        <div class="flex items-center gap-3 mb-5">
          <div class="w-10 h-10 rounded-xl bg-error/20 flex items-center justify-center">
            <.icon name="hero-trash" class="w-5 h-5 text-error" />
          </div>
          <div>
            <h3 class="font-bold text-lg">Trash {file_count(@count)}?</h3>
            <p class="text-sm text-base-content/60">
              Across {item_count(@items)}, reclaiming {humanize_bytes(@bytes)}.
            </p>
          </div>
        </div>

        <p class="py-2">
          Every selected file is a redundant copy of one that stays behind, so each item keeps
          a playable file. Trashed files are kept for {@retention_days} days before permanent
          deletion.
        </p>

        <div class="modal-action mt-6 pt-4 border-t border-base-300">
          <button id="prune-cancel" type="button" class="btn btn-ghost" phx-click="close_prune_modal">
            Cancel
          </button>
          <button
            id="prune-confirm"
            type="button"
            class="btn btn-error"
            phx-click="confirm_prune"
            phx-disable-with="Trashing..."
          >
            <.icon name="hero-trash" class="w-4 h-4" /> Move to trash
          </button>
        </div>
      </div>
      <div class="modal-backdrop bg-black/50" phx-click="close_prune_modal"></div>
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

  defp file_count(1), do: "1 file"
  defp file_count(n), do: "#{n} files"

  defp item_count(1), do: "1 item"
  defp item_count(n), do: "#{n} items"

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
