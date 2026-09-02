defmodule MydiaWeb.AdminTrashLive.Components do
  @moduledoc """
  Presentation for the trash page.

  Every helper here is total over the data the page can actually hold. A
  trashed row may have no size and no reason, and both render rather than
  raise.
  """
  use MydiaWeb, :html

  alias Mydia.Library.MediaFile

  @reasons [
    {:missing, "Missing", "The file was gone from disk when a scan looked for it"},
    {:upgraded, "Upgraded", "A better release replaced this file"},
    {:upgrade_rejected, "Rejected", "This release did not deliver the quality it claimed"},
    {:pruned, "Pruned", "A redundant copy, removed in favour of a keeper"},
    {:manual, "Manual", "Someone deleted this file by hand"},
    {:unknown, "Unknown", "Trashed before Mydia recorded a reason"}
  ]

  @doc "The reason list, for the filter chips and the row badges."
  def reasons, do: @reasons

  attr :summary, :map, required: true
  attr :retention_days, :integer, required: true

  def summary_bar(assigns) do
    ~H"""
    <div id="trash-summary" class="flex flex-wrap items-center gap-3 mb-6">
      <div class="flex items-center gap-2">
        <.icon name="hero-trash" class="w-5 h-5 text-base-content/60" />
        <span class="font-semibold">{file_count(@summary.count)}</span>
        <span class="text-base-content/60">
          · {humanize_bytes(@summary.bytes)} tracked · purged after {@retention_days} days
        </span>
      </div>

      <div class="ml-auto flex gap-2">
        <button id="trash-scan" type="button" class="btn btn-sm btn-ghost" phx-click="scan_directory">
          <.icon name="hero-magnifying-glass" class="w-4 h-4" /> Scan trash directory
        </button>
        <button
          id="trash-empty"
          type="button"
          class="btn btn-sm btn-error"
          phx-click="confirm_empty"
          disabled={@summary.count == 0}
        >
          <.icon name="hero-trash" class="w-4 h-4" /> Empty trash now
        </button>
      </div>
    </div>
    """
  end

  attr :counts, :map, required: true
  attr :active, :atom, default: nil

  def reason_filters(assigns) do
    ~H"""
    <div class="filter mb-5">
      <input
        id="trash-filter-all"
        class="btn btn-sm"
        type="radio"
        name="trash_reason"
        aria-label="All"
        checked={is_nil(@active)}
        phx-click="filter_reason"
        phx-value-reason=""
      />
      <%= for {reason, label, _hint} <- reasons(), count_for(@counts, reason) > 0 do %>
        <input
          id={"trash-filter-#{reason}"}
          class="btn btn-sm"
          type="radio"
          name="trash_reason"
          aria-label={"#{label} (#{count_for(@counts, reason)})"}
          checked={@active == reason}
          phx-click="filter_reason"
          phx-value-reason={reason}
        />
      <% end %>
    </div>
    """
  end

  attr :files, :list, required: true
  attr :retention_days, :integer, required: true
  attr :selection, :any, required: true

  def trash_list(assigns) do
    ~H"""
    <div id="trash-list" class="space-y-2">
      <div :if={@files == []} class="text-center py-12 text-base-content/60">
        Nothing in the trash.
      </div>

      <div
        :for={file <- @files}
        id={"trash-row-#{file.id}"}
        class="flex items-center gap-4 p-4 rounded-lg border border-base-300 hover:border-base-content/20 transition-colors"
      >
        <input
          id={"trash-select-#{file.id}"}
          type="checkbox"
          class="checkbox checkbox-sm"
          checked={selected?(@selection, file.id)}
          phx-click="toggle_select"
          phx-value-id={file.id}
        />

        <div class="min-w-0 flex-1">
          <div class="font-medium truncate">{label_for(file)}</div>
          <div class="text-sm text-base-content/60 flex items-center gap-2 mt-0.5">
            <span
              id={"trash-reason-#{file.id}"}
              class={["badge badge-sm", badge_class(file.trashed_reason)]}
            >
              {reason_label(file.trashed_reason)}
            </span>
            <span>{humanize_bytes(file.size)}</span>
            <span>· trashed {relative_age(file.trashed_at)}</span>
            <span>· purges {purge_due(file.trashed_at, @retention_days)}</span>
          </div>
        </div>

        <div class="flex gap-2 flex-shrink-0">
          <button
            id={"trash-restore-#{file.id}"}
            type="button"
            class="btn btn-sm btn-ghost"
            phx-click="restore_file"
            phx-value-id={file.id}
          >
            <.icon name="hero-arrow-uturn-left" class="w-4 h-4" /> Restore
          </button>
          <button
            id={"trash-purge-#{file.id}"}
            type="button"
            class="btn btn-sm btn-ghost text-error"
            phx-click="purge_file"
            phx-value-id={file.id}
            data-confirm="Permanently delete this file? This cannot be undone."
          >
            <.icon name="hero-x-mark" class="w-4 h-4" /> Delete
          </button>
        </div>
      </div>
    </div>
    """
  end

  def selected?({:all_matching, _reason}, _id), do: true
  def selected?(%MapSet{} = ids, id), do: MapSet.member?(ids, id)

  def selection_count({:all_matching, _reason}, total_matching), do: total_matching
  def selection_count(%MapSet{} = ids, _total), do: MapSet.size(ids)

  attr :selection, :any, required: true
  attr :total_matching, :integer, required: true
  attr :page_size, :integer, required: true

  def bulk_bar(assigns) do
    ~H"""
    <div
      :if={selection_count(@selection, @total_matching) > 0}
      id="trash-bulk-bar"
      class="flex flex-wrap items-center gap-3 mb-4 p-3 rounded-lg bg-base-200"
    >
      <span class="font-medium">
        {selection_count(@selection, @total_matching)} selected
      </span>

      <button id="trash-bulk-restore" type="button" class="btn btn-sm" phx-click="bulk_restore">
        <.icon name="hero-arrow-uturn-left" class="w-4 h-4" /> Restore
      </button>
      <button
        id="trash-bulk-purge"
        type="button"
        class="btn btn-sm btn-error"
        phx-click="bulk_purge"
        data-confirm="Permanently delete every selected file? This cannot be undone."
      >
        <.icon name="hero-x-mark" class="w-4 h-4" /> Delete permanently
      </button>

      <button
        id="trash-clear-selection"
        type="button"
        class="btn btn-sm btn-ghost"
        phx-click="clear_selection"
      >
        Clear
      </button>

      <%!--
        Only offered when the page cannot already hold the whole match: the
        escape hatch exists because pagination means ticking every visible box
        still misses everything on later pages.
      --%>
      <button
        :if={not match?({:all_matching, _}, @selection) and @total_matching > @page_size}
        id="trash-select-all-matching"
        type="button"
        class="btn btn-sm btn-ghost"
        phx-click="select_all_matching"
      >
        Select all {@total_matching} matching
      </button>
    </div>
    """
  end

  attr :page, :integer, required: true
  attr :page_size, :integer, required: true
  attr :total_matching, :integer, required: true

  def pagination(assigns) do
    assigns =
      assigns
      |> assign(:last_page, div(assigns.total_matching - 1, assigns.page_size))
      |> assign(:from, assigns.page * assigns.page_size + 1)
      |> assign(:to, min((assigns.page + 1) * assigns.page_size, assigns.total_matching))

    ~H"""
    <div id="trash-pagination" class="flex items-center justify-between gap-3 mt-4">
      <span class="text-sm text-base-content/60">
        Showing {@from}-{@to} of {@total_matching}
      </span>

      <div class="join">
        <button
          id="trash-page-prev"
          type="button"
          class="btn btn-sm join-item"
          disabled={@page == 0}
          phx-click="paginate"
          phx-value-page={@page - 1}
        >
          <.icon name="hero-chevron-left" class="w-4 h-4" /> Prev
        </button>
        <button
          id="trash-page-next"
          type="button"
          class="btn btn-sm join-item"
          disabled={@page >= @last_page}
          phx-click="paginate"
          phx-value-page={@page + 1}
        >
          Next <.icon name="hero-chevron-right" class="w-4 h-4" />
        </button>
      </div>
    </div>
    """
  end

  attr :count, :integer, required: true
  attr :bytes, :integer, required: true

  def empty_confirm_modal(assigns) do
    ~H"""
    <div id="trash-empty-modal" class="modal modal-open">
      <div class="modal-box">
        <div class="flex items-center gap-3 mb-5">
          <div class="w-10 h-10 rounded-xl bg-error/20 flex items-center justify-center">
            <.icon name="hero-trash" class="w-5 h-5 text-error" />
          </div>
          <div>
            <h3 class="font-bold text-lg">Empty the trash?</h3>
            <p class="text-sm text-base-content/60">
              {file_count(@count)}, reclaiming {humanize_bytes(@bytes)}.
            </p>
          </div>
        </div>

        <p class="py-2">
          This purges everything in the trash now, including files trashed moments ago, rather
          than waiting out the retention period. Rows trashed because their file had already
          vanished from disk only lose the row; nothing on your library path is touched.
        </p>

        <div class="modal-action mt-6 pt-4 border-t border-base-300">
          <button id="trash-empty-cancel" type="button" class="btn btn-ghost" phx-click="close_modal">
            Cancel
          </button>
          <button
            id="trash-empty-confirm"
            type="button"
            class="btn btn-error"
            phx-click="empty_trash"
            phx-disable-with="Emptying..."
          >
            <.icon name="hero-trash" class="w-4 h-4" /> Empty trash
          </button>
        </div>
      </div>
      <div class="modal-backdrop bg-black/50" phx-click="close_modal"></div>
    </div>
    """
  end

  attr :audit, :map, required: true

  def audit_result(assigns) do
    ~H"""
    <div :if={audit_total(@audit) > 0} id="trash-audit" class="alert alert-warning mb-5">
      <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
      <div>
        <div class="font-medium">
          {file_count(audit_total(@audit))} in the trash directory that nothing will purge
        </div>
        <div class="text-sm opacity-80">
          {length(@audit.retained)} kept by a restore that found the library path occupied, {length(
            @audit.orphaned
          )} with no record behind them.
          Total {humanize_bytes(audit_bytes(@audit))}.
        </div>
      </div>
      <button id="trash-sweep" type="button" class="btn btn-sm" phx-click="sweep">
        Sweep them
      </button>
    </div>
    """
  end

  defp audit_total(audit), do: length(audit.retained) + length(audit.orphaned)

  defp audit_bytes(audit) do
    (audit.retained ++ audit.orphaned) |> Enum.map(& &1.bytes) |> Enum.sum()
  end

  defp count_for(counts, :unknown), do: Map.get(counts, nil, 0)
  defp count_for(counts, reason), do: Map.get(counts, reason, 0)

  defp reason_label(nil), do: "Unknown"

  defp reason_label(reason) do
    case Enum.find(@reasons, fn {r, _, _} -> r == reason end) do
      {_, label, _} -> label
      nil -> "Unknown"
    end
  end

  defp badge_class(:missing), do: "badge-warning"
  defp badge_class(:upgraded), do: "badge-success"
  defp badge_class(:upgrade_rejected), do: "badge-error"
  defp badge_class(:pruned), do: "badge-info"
  defp badge_class(:manual), do: "badge-neutral"
  defp badge_class(_), do: "badge-ghost"

  # An episode's media_files row carries episode_id with media_item_id NULL;
  # the show hangs off episode.media_item rather than off the file directly.
  # See lib/mydia/media/README.md ("A TV media_file has media_item_id NULL"),
  # which documents this exact shape shipping broken twice before (PR #430,
  # PR #439). The episode clause is matched first, and ahead of the movie
  # clause below, since a file could in principle carry both keys and the
  # episode is the one that renders a useful label.
  #
  # A trashed row can have no media item at all (an episode whose show was
  # deleted, or neither association loaded), so relative_path is the
  # fallback label rather than a crash.
  def label_for(%MediaFile{
        episode: %{media_item: %{title: title}, season_number: s, episode_number: e}
      })
      when is_binary(title) do
    "#{title} S#{pad(s)}E#{pad(e)}"
  end

  def label_for(%MediaFile{media_item: %{title: title}}) when is_binary(title), do: title

  def label_for(%MediaFile{relative_path: path}) when is_binary(path), do: path
  def label_for(%MediaFile{}), do: "Unknown file"

  defp pad(nil), do: "??"
  defp pad(n), do: String.pad_leading(to_string(n), 2, "0")

  defp file_count(1), do: "1 file"
  defp file_count(n), do: "#{n} files"

  def humanize_bytes(nil), do: "unknown"

  def humanize_bytes(bytes) when bytes >= 1_073_741_824,
    do: "#{Float.round(bytes / 1_073_741_824, 1)} GB"

  def humanize_bytes(bytes) when bytes >= 1_048_576,
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  def humanize_bytes(bytes), do: "#{bytes} B"

  defp relative_age(nil), do: "at an unknown time"

  defp relative_age(%DateTime{} = at) do
    case DateTime.diff(DateTime.utc_now(), at, :day) do
      0 -> "today"
      1 -> "yesterday"
      n -> "#{n} days ago"
    end
  end

  defp purge_due(nil, _days), do: "on an unknown date"

  defp purge_due(%DateTime{} = at, days) do
    case days - DateTime.diff(DateTime.utc_now(), at, :day) do
      n when n <= 0 -> "on the next cleanup run"
      1 -> "tomorrow"
      n -> "in #{n} days"
    end
  end
end
