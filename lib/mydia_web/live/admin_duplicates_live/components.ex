defmodule MydiaWeb.AdminDuplicatesLive.Components do
  @moduledoc """
  Function components for the duplicates review page. Used only by the sibling
  LiveView.

  Every file row carries one control: a Keep/Trash pair of radios in a `join`,
  so the row states its current disposition in words and the alternative sits
  next to it. An earlier revision paired an unlabelled keeper radio on the
  left with an unlabelled red checkbox on the right, which left an operator
  with two controls, no labels, and no way to tell which one decided the
  file's fate.

  Each group carries two buttons rather than one that swaps meaning: a marking
  toggle, and a button that actually trashes. The marking half still swaps its
  label so the row never goes dead once everything in it is kept.
  """

  use MydiaWeb, :html

  alias Mydia.Library.MediaFile

  @doc """
  Renders the Duplicates tab content.
  """
  attr :decisions, :list, required: true
  attr :refusals, :list, required: true
  attr :selected, :any, required: true
  attr :reclaimable, :integer, required: true
  attr :retention_days, :integer, required: true

  def duplicates_tab(assigns) do
    total_losers =
      Enum.reduce(assigns.decisions, 0, fn decision, acc -> acc + length(decision.losers) end)

    assigns = assign(assigns, :all_selected?, MapSet.size(assigns.selected) == total_losers)

    ~H"""
    <div class="p-4 sm:p-6 space-y-4">
      <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
        <h2 class="text-lg font-semibold flex items-center gap-2">
          <.icon name="hero-document-duplicate" class="w-5 h-5 opacity-60" /> Duplicates
          <span class="badge badge-ghost">{length(@decisions)}</span>
        </h2>
        <div class="join">
          <button
            :if={not @all_selected?}
            id="duplicates-trash-all"
            type="button"
            class="btn btn-sm btn-ghost join-item"
            phx-click="trash_all_duplicates"
          >
            <.icon name="hero-check-circle" class="w-4 h-4" /> Mark all for trash
          </button>
          <button
            id="duplicates-trash-selected"
            type="button"
            class="btn btn-sm btn-error join-item"
            disabled={MapSet.size(@selected) == 0}
            phx-click="open_trash_modal"
          >
            <.icon name="hero-trash" class="w-4 h-4" />
            Trash {file_count(MapSet.size(@selected))} ({humanize_bytes(@reclaimable)})
          </button>
        </div>
      </div>

      <p class="text-sm text-base-content/60">
        Items holding more than one file, where every copy is proven to be the same content.
        Each file is set to either <span class="font-medium text-base-content">Keep</span>
        or <span class="font-medium text-error">Trash</span>; the best copy is listed first and
        kept, the rest are already marked for trash. Trash one item with its own button, or
        every item with the button above. Every item always keeps at least one file. Trashed
        files are held for {@retention_days} days before permanent deletion, and a run can be
        undone until you leave this page.
      </p>

      <%= if @decisions == [] do %>
        <div class="alert alert-info">
          <.icon name="hero-information-circle" class="w-5 h-5" />
          <span :if={@refusals == []}>
            No item holds more than one file. There are no duplicates to review.
          </span>
          <span :if={@refusals != []}>
            Nothing can be trashed safely right now. Every item below needs attention first.
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
          These were left alone. Each one is a matching or scanning problem rather than a
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
    selected = assigns.selected
    marked = Enum.filter(assigns.decision.losers, &MapSet.member?(selected, &1.id))

    assigns =
      assigns
      |> assign(:selected_count, length(marked))
      |> assign(:selected_bytes, Enum.reduce(marked, 0, &(&2 + (&1.size || 0))))
      |> assign(:files, [assigns.decision.keeper | assigns.decision.losers])

    ~H"""
    <div class="p-3 sm:p-4" id={"duplicates-group-#{@decision.group.subject_id}"}>
      <div class="flex items-center gap-3">
        <div class="flex-1 min-w-0">
          <div class="font-medium truncate">{subject_label(@decision.group)}</div>
          <div class="text-xs opacity-60 truncate">{@decision.reason}</div>
        </div>

        <span class="badge badge-sm badge-outline hidden sm:inline-flex">
          {file_count(length(@files))}
        </span>
        <span :if={@selected_count > 0} class="badge badge-sm badge-outline badge-error">
          {@selected_count} to trash
        </span>
        <span :if={@selected_count == 0} class="badge badge-sm badge-outline">Keeping all</span>

        <button
          id={"duplicates-group-mark-#{@decision.group.subject_id}"}
          type="button"
          class="btn btn-sm btn-ghost ml-auto sm:ml-2"
          aria-label={
            if @selected_count > 0,
              do: "Keep every file in #{subject_label(@decision.group)}",
              else: "Mark every duplicate in #{subject_label(@decision.group)} for trash"
          }
          phx-click={if @selected_count > 0, do: "keep_group", else: "trash_group"}
          phx-value-subject={@decision.group.subject_id}
        >
          {if @selected_count > 0, do: "Keep all", else: "Mark all for trash"}
        </button>
        <button
          id={"duplicates-group-trash-#{@decision.group.subject_id}"}
          type="button"
          class="btn btn-sm btn-error"
          disabled={@selected_count == 0}
          aria-label={"Trash the marked duplicates in #{subject_label(@decision.group)}"}
          phx-click="trash_group_now"
          phx-value-subject={@decision.group.subject_id}
          phx-disable-with="Trashing..."
        >
          <.icon name="hero-trash" class="w-4 h-4" />
          Trash {file_count(@selected_count)} ({humanize_bytes(@selected_bytes)})
        </button>
      </div>

      <div class="bg-base-100 rounded-box divide-y divide-base-300 mt-3">
        <.file_row
          :for={file <- @files}
          file={file}
          subject_id={@decision.group.subject_id}
          trashing?={MapSet.member?(@selected, file.id)}
          best?={file.id == @decision.keeper.id}
        />
      </div>
    </div>
    """
  end

  attr :file, :map, required: true
  attr :subject_id, :string, required: true
  attr :trashing?, :boolean, required: true
  attr :best?, :boolean, required: true

  defp file_row(assigns) do
    assigns =
      assigns
      |> assign(:name, Path.basename(assigns.file.relative_path))
      |> assign(:folder, folder_of(assigns.file.relative_path))

    ~H"""
    <div class="flex items-center gap-3 px-3 py-2">
      <div class="flex-1 min-w-0">
        <%!--
        The filename, not the whole relative path. Copies of one item share a
        folder and differ in the tail of their name ("...1080p.BluRay.x265"),
        which is exactly what a truncated path column cuts off first, leaving
        an operator three rows they cannot tell apart.
        --%>
        <div class={["truncate text-sm", @trashing? && "line-through opacity-50"]}>{@name}</div>
        <div :if={@folder} class="truncate text-xs opacity-50">{@folder}</div>
      </div>

      <span :if={@best? and not @trashing?} class="badge badge-sm badge-ghost hidden sm:inline-flex">
        Best copy
      </span>
      <span class="badge badge-ghost badge-sm">{quality_label(@file)}</span>
      <span class="text-xs opacity-60 whitespace-nowrap">{humanize_bytes(@file.size)}</span>

      <%!--
      One radiogroup per file, not a checkbox: the two options are named on
      screen, so the row reads as a state ("this file is set to Keep") and the
      other half of the pair reads as the action. daisyUI renders the
      aria-label of an input styled `.btn` as its text.
      --%>
      <div
        class="join shrink-0"
        role="radiogroup"
        aria-label={"Disposition for #{@file.relative_path}"}
      >
        <input
          type="radio"
          class="join-item btn btn-xs"
          id={"duplicates-keep-#{@file.id}"}
          name={"disposition-#{@file.id}"}
          aria-label="Keep"
          checked={not @trashing?}
          phx-click="keep_file"
          phx-value-subject={@subject_id}
          phx-value-file={@file.id}
        />
        <%!--
        `btn-error` and `checked:btn-error` both lose to daisyUI's own
        "a checked .btn is primary" rule, which sits in the outer
        `daisyui.l1` cascade layer and so outranks every colour class in the
        nested layers no matter how specific. Setting the variables that rule
        writes is the way to recolour it: an arbitrary property lands outside
        daisyUI's layers entirely.
        --%>
        <input
          type="radio"
          class={[
            "join-item btn btn-xs",
            @trashing? && "[--btn-color:var(--color-error)] [--btn-fg:var(--color-error-content)]"
          ]}
          id={"duplicates-trash-#{@file.id}"}
          name={"disposition-#{@file.id}"}
          aria-label="Trash"
          checked={@trashing?}
          phx-click="trash_file"
          phx-value-subject={@subject_id}
          phx-value-file={@file.id}
        />
      </div>
    </div>
    """
  end

  # Library-relative folder for a file, or nil when the file sits at the root
  # of its library path and there is nothing useful to show.
  defp folder_of(relative_path) do
    case Path.dirname(relative_path) do
      "." -> nil
      "/" -> nil
      folder -> folder
    end
  end

  attr :group, :map, required: true
  attr :reason, :atom, required: true
  attr :detail, :map, required: true

  defp refusal_row(assigns) do
    ~H"""
    <div class="p-3 sm:p-4" id={"duplicates-refusal-#{@group.subject_id}"}>
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
  every file marked for trash across the whole library in one go. The blast
  radius (files, items, bytes) is worth showing before it runs.
  """
  attr :count, :integer, required: true
  attr :items, :integer, required: true
  attr :bytes, :integer, required: true
  attr :retention_days, :integer, required: true

  def trash_confirm_modal(assigns) do
    ~H"""
    <div id="duplicates-confirm-modal" class="modal modal-open">
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
          Every file marked for trash is a redundant copy of one set to Keep, so each item keeps
          a playable file. Trashed files are held for {@retention_days} days before permanent
          deletion.
        </p>

        <div class="modal-action mt-6 pt-4 border-t border-base-300">
          <button
            id="duplicates-cancel"
            type="button"
            class="btn btn-ghost"
            phx-click="close_trash_modal"
          >
            Cancel
          </button>
          <button
            id="duplicates-confirm"
            type="button"
            class="btn btn-error"
            phx-click="confirm_trash"
            phx-disable-with="Trashing..."
          >
            <.icon name="hero-trash" class="w-4 h-4" /> Move to trash
          </button>
        </div>
      </div>
      <div class="modal-backdrop bg-black/50" phx-click="close_trash_modal"></div>
    </div>
    """
  end

  @doc """
  The undo affordance for a completed trash run.

  This cannot be a flash. `core_components.ex` puts
  `phx-click="lv:clear-flash"` on the whole flash container, which would
  swallow a nested Undo button, and flash values are strings, so the file ids
  would need an assign regardless.

  It sits bottom-end because the flash group sits top-end, and a partial run
  shows both: an error flash for what could not move, and this for what did.

  There is no auto-dismiss timer. Any interval is a guess, and an operator
  reading filenames to check they trashed the right copy will lose that race.
  """
  attr :run, :map, required: true

  def undo_toast(assigns) do
    ~H"""
    <div id="duplicates-undo-toast" class="toast toast-bottom toast-end z-50" role="status">
      <div class="alert alert-success w-80 sm:w-96 max-w-80 sm:max-w-96 text-wrap">
        <.icon name="hero-check-circle" class="size-5 shrink-0" />
        <span class="text-sm">{@run.label}</span>
        <div class="flex-1" />
        <button
          id="duplicates-undo"
          type="button"
          class="btn btn-sm btn-ghost"
          phx-click="undo_trash"
          phx-disable-with="Undoing..."
        >
          <.icon name="hero-arrow-uturn-left" class="w-4 h-4" /> Undo
        </button>
        <button
          id="duplicates-undo-dismiss"
          type="button"
          class="group self-start cursor-pointer"
          aria-label="Dismiss"
          phx-click="dismiss_undo"
        >
          <.icon name="hero-x-mark" class="size-5 opacity-40 group-hover:opacity-70" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  The operator-facing name of a group's subject. Public because the LiveView
  builds the undo toast's label from it, and a movie title or a
  "Show S01E02" string is a display concern that belongs here rather than
  duplicated in the page module.
  """
  def subject_label(%{subject_type: :movie, subject: movie}), do: movie.title

  def subject_label(%{subject_type: :episode, subject: episode, media_item: show}) do
    "#{show.title} S#{pad(episode.season_number)}E#{pad(episode.episode_number)}"
  end

  defp pad(nil), do: "??"
  defp pad(n), do: String.pad_leading(to_string(n), 2, "0")

  defp quality_label(%MediaFile{} = file) do
    [file.resolution, file.codec] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end

  @doc """
  Pluralized counts. Public for the same reason `humanize_bytes/1` is: the page
  module builds the undo toast's label and must count files and items the same
  way the rows above it do.
  """
  def file_count(1), do: "1 file"
  def file_count(n), do: "#{n} files"

  def item_count(1), do: "1 item"
  def item_count(n), do: "#{n} items"

  defp refusal_label(:duplicate_registration), do: "Registered twice"
  defp refusal_label(:unanalyzed), do: "Not analyzed"
  defp refusal_label(:duration_mismatch), do: "Different lengths"
  defp refusal_label(:name_mismatch), do: "Names disagree"
  defp refusal_label(:episode_mismatch), do: "Wrong episode"
  defp refusal_label(:nothing_to_prune), do: "Nothing to trash"

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
    "At least one filename does not belong to this item. Fix the match before trashing anything."
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
