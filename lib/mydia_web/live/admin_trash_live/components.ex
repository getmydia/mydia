defmodule MydiaWeb.AdminTrashLive.Components do
  @moduledoc """
  Presentation for the trash page.

  Every helper here is total over the data the page can actually hold. A
  trashed row may have no size and no reason, and both render rather than
  raise.
  """
  use MydiaWeb, :html

  import MydiaWeb.Formatters, only: [format_file_size: 1]

  alias Mydia.Library.MediaFile

  @doc """
  The reason list as `{key, label, hint}`, for the filter segmented control and
  the row badges. Built per call: the labels are translated, so they cannot
  live in a module attribute.
  """
  def reasons do
    [
      {:upgraded, pgettext("trash reason", "Upgraded"),
       gettext("A better release replaced this file")},
      {:upgrade_rejected, pgettext("trash reason", "Rejected"),
       gettext("This release did not deliver the quality it claimed")},
      {:pruned, pgettext("trash reason", "Pruned"),
       gettext("A redundant copy, removed in favour of a keeper")},
      {:manual, pgettext("trash reason", "Manual"), gettext("Someone deleted this file by hand")},
      {:unknown, pgettext("trash reason", "Unknown"),
       gettext("Trashed before Mydia recorded a reason")}
    ]
  end

  attr :summary, :map, required: true
  attr :retention_days, :integer, required: true
  attr :scanning, :boolean, required: true
  attr :sweeping, :boolean, required: true
  attr :audit, :map, default: nil
  attr :counts, :map, required: true
  attr :reason, :atom, default: nil
  attr :selection, :any, required: true
  attr :total_matching, :integer, required: true
  attr :page_size, :integer, required: true
  attr :files, :list, required: true
  attr :page, :integer, required: true

  def trash_tab(assigns) do
    ~H"""
    <div id="trash-content" class="space-y-4">
      <.summary_bar summary={@summary} retention_days={@retention_days} />

      <div :if={@scanning} class="alert">
        <span class="loading loading-spinner loading-sm"></span>
        {gettext("Reading the trash directory...")}
      </div>

      <div :if={@sweeping} class="alert">
        <span class="loading loading-spinner loading-sm"></span>
        {gettext("Sweeping the trash directory...")}
      </div>

      <.audit_result :if={@audit} audit={@audit} />

      <.reason_filters counts={@counts} active={@reason} />

      <.bulk_bar
        selection={@selection}
        total_matching={@total_matching}
        page_size={@page_size}
      />

      <.trash_list
        files={@files}
        retention_days={@retention_days}
        selection={@selection}
      />

      <.pagination
        :if={@total_matching > @page_size}
        page={@page}
        page_size={@page_size}
        total_matching={@total_matching}
      />
    </div>
    """
  end

  @doc "The page header's scan and empty buttons."
  attr :summary, :map, required: true

  def header_actions(assigns) do
    ~H"""
    <div class="join">
      <button
        id="trash-scan"
        type="button"
        class="btn btn-sm btn-ghost join-item"
        phx-click="scan_trash_directory"
      >
        <.icon name="hero-magnifying-glass" class="w-4 h-4" /> {gettext("Scan directory")}
      </button>
      <button
        id="trash-empty"
        type="button"
        class="btn btn-sm btn-error join-item"
        phx-click="open_empty_trash_modal"
        disabled={@summary.count == 0}
      >
        <.icon name="hero-trash" class="w-4 h-4" /> {gettext("Empty trash")}
      </button>
    </div>
    """
  end

  attr :summary, :map, required: true
  attr :retention_days, :integer, required: true

  def summary_bar(assigns) do
    ~H"""
    <p id="trash-summary" class="text-sm text-base-content/60">
      {ngettext(
        "%{count} file tracked, using %{size}.",
        "%{count} files tracked, using %{size}.",
        @summary.count,
        size: format_file_size(@summary.bytes)
      )}
      {ngettext(
        "Files are permanently deleted after %{count} day.",
        "Files are permanently deleted after %{count} days.",
        @retention_days
      )}
    </p>
    """
  end

  attr :counts, :map, required: true
  attr :active, :atom, default: nil

  def reason_filters(assigns) do
    ~H"""
    <div
      class="overflow-x-auto"
      data-scroll-ok="segmented control is a non-wrapping join; scrolls only itself"
    >
      <.segmented_control
        id="trash-reason-filter"
        value={@active || ""}
        event="filter_trash"
        param="reason"
        label={gettext("Filter by reason")}
      >
        <:option value="" label={pgettext("selection", "All")} id="trash-filter-all" />
        <:option
          :for={{reason, label, _hint} <- visible_reasons(@counts)}
          value={reason}
          label={gettext("%{label} (%{count})", label: label, count: count_for(@counts, reason))}
          id={"trash-filter-#{reason}"}
        />
      </.segmented_control>
    </div>
    """
  end

  attr :files, :list, required: true
  attr :retention_days, :integer, required: true
  attr :selection, :any, required: true

  def trash_list(assigns) do
    ~H"""
    <.admin_list id="trash-list" items={@files}>
      <:empty>{gettext("Nothing in the trash.")}</:empty>
      <:row :let={file}>
        <.admin_row id={"trash-row-#{file.id}"}>
          <:title>
            <input
              id={"trash-select-#{file.id}"}
              type="checkbox"
              class="checkbox checkbox-sm"
              checked={selected?(@selection, file.id)}
              phx-click="toggle_trash_selection"
              phx-value-id={file.id}
            />
            {label_for(file)}
          </:title>
          <:descriptor>
            {gettext("%{size} · Trashed %{age} · Purges %{due}",
              size: format_file_size(file.size),
              age: relative_age(file.trashed_at),
              due: purge_due(file.trashed_at, @retention_days)
            )}
          </:descriptor>
          <:badges>
            <span
              id={"trash-reason-#{file.id}"}
              class={["badge badge-sm", badge_class(file.trashed_reason)]}
            >
              {reason_label(file.trashed_reason)}
            </span>
          </:badges>
          <:actions>
            <.row_actions>
              <.row_action
                id={"trash-restore-#{file.id}"}
                icon="hero-arrow-uturn-left"
                title={gettext("Restore")}
                phx-click="restore_trash_file"
                phx-value-id={file.id}
              />
              <.row_action
                id={"trash-purge-#{file.id}"}
                icon="hero-x-mark"
                title={gettext("Delete permanently")}
                destructive
                phx-click="purge_trash_file"
                phx-value-id={file.id}
                data-confirm={gettext("Permanently delete this file? This cannot be undone.")}
              />
            </.row_actions>
          </:actions>
        </.admin_row>
      </:row>
    </.admin_list>
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
      class="flex flex-wrap items-center gap-3 p-3 rounded-lg bg-base-200"
    >
      <span class="font-medium">
        {ngettext(
          "%{count} selected",
          "%{count} selected",
          selection_count(@selection, @total_matching)
        )}
      </span>

      <button
        id="trash-bulk-restore"
        type="button"
        class="btn btn-sm"
        phx-click="restore_selected_trash"
      >
        <.icon name="hero-arrow-uturn-left" class="w-4 h-4" /> {gettext("Restore")}
      </button>
      <button
        id="trash-bulk-purge"
        type="button"
        class="btn btn-sm btn-error"
        phx-click="purge_selected_trash"
        data-confirm={gettext("Permanently delete every selected file? This cannot be undone.")}
      >
        <.icon name="hero-x-mark" class="w-4 h-4" /> {gettext("Delete permanently")}
      </button>

      <button
        id="trash-clear-selection"
        type="button"
        class="btn btn-sm btn-ghost"
        phx-click="clear_trash_selection"
      >
        {pgettext("selection", "Clear")}
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
        phx-click="select_all_trash"
      >
        {ngettext(
          "Select all %{count} matching",
          "Select all %{count} matching",
          @total_matching
        )}
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
    <div id="trash-pagination" class="flex items-center justify-between gap-3">
      <span class="text-sm text-base-content/60">
        {gettext("Showing %{from}-%{to} of %{total}",
          from: @from,
          to: @to,
          total: @total_matching
        )}
      </span>

      <div class="join">
        <button
          id="trash-page-prev"
          type="button"
          class="btn btn-sm join-item"
          disabled={@page == 0}
          phx-click="paginate_trash"
          phx-value-page={@page - 1}
        >
          <.icon name="hero-chevron-left" class="w-4 h-4" /> {gettext("Prev")}
        </button>
        <button
          id="trash-page-next"
          type="button"
          class="btn btn-sm join-item"
          disabled={@page >= @last_page}
          phx-click="paginate_trash"
          phx-value-page={@page + 1}
        >
          {gettext("Next")} <.icon name="hero-chevron-right" class="w-4 h-4" />
        </button>
      </div>
    </div>
    """
  end

  attr :count, :integer, required: true
  attr :bytes, :integer, required: true

  def empty_confirm_modal(assigns) do
    ~H"""
    <.admin_modal
      id="trash-empty-modal"
      tone={:error}
      icon="hero-trash"
      title={gettext("Empty the trash?")}
      subtitle={
        ngettext(
          "%{count} file, reclaiming %{size}.",
          "%{count} files, reclaiming %{size}.",
          @count,
          size: format_file_size(@bytes)
        )
      }
      on_close="close_empty_trash_modal"
    >
      <p class="py-2">
        {gettext(
          "This purges everything in the trash now, including files trashed moments ago, rather than waiting out the retention period."
        )}
        {gettext(
          "Rows trashed because their file had already vanished from disk only lose the row; nothing on your library path is touched."
        )}
      </p>

      <:actions>
        <button
          id="trash-empty-cancel"
          type="button"
          class="btn btn-ghost"
          phx-click="close_empty_trash_modal"
        >
          {gettext("Cancel")}
        </button>
        <button
          id="trash-empty-confirm"
          type="button"
          class="btn btn-error"
          phx-click="empty_trash"
          phx-disable-with={gettext("Emptying...")}
        >
          <.icon name="hero-trash" class="w-4 h-4" /> {gettext("Empty trash")}
        </button>
      </:actions>
    </.admin_modal>
    """
  end

  attr :audit, :map, required: true

  def audit_result(assigns) do
    ~H"""
    <div :if={audit_total(@audit) > 0} id="trash-audit" class="alert alert-warning">
      <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
      <div>
        <div class="font-medium">
          {ngettext(
            "%{count} file in the trash directory that nothing will purge",
            "%{count} files in the trash directory that nothing will purge",
            audit_total(@audit)
          )}
        </div>
        <div class="text-sm opacity-80">
          {gettext(
            "%{retained} kept by a restore that found the library path occupied, %{orphaned} with no record behind them.",
            retained: length(@audit.retained),
            orphaned: length(@audit.orphaned)
          )}
          {gettext("Total %{size}.", size: format_file_size(audit_bytes(@audit)))}
        </div>
      </div>
      <button id="trash-sweep" type="button" class="btn btn-sm" phx-click="sweep_trash">
        {gettext("Sweep them")}
      </button>
    </div>
    """
  end

  defp audit_total(audit), do: length(audit.retained) + length(audit.orphaned)

  defp audit_bytes(audit) do
    (audit.retained ++ audit.orphaned) |> Enum.map(& &1.bytes) |> Enum.sum()
  end

  defp visible_reasons(counts),
    do: Enum.filter(reasons(), fn {r, _, _} -> count_for(counts, r) > 0 end)

  defp count_for(counts, :unknown), do: Map.get(counts, nil, 0)
  defp count_for(counts, reason), do: Map.get(counts, reason, 0)

  defp reason_label(nil), do: pgettext("trash reason", "Unknown")

  defp reason_label(reason) do
    case Enum.find(reasons(), fn {r, _, _} -> r == reason end) do
      {_, label, _} -> label
      nil -> pgettext("trash reason", "Unknown")
    end
  end

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
  def label_for(%MediaFile{}), do: gettext("Unknown file")

  defp pad(nil), do: "??"
  defp pad(n), do: String.pad_leading(to_string(n), 2, "0")

  defp relative_age(nil), do: gettext("at an unknown time")

  defp relative_age(%DateTime{} = at) do
    case DateTime.diff(DateTime.utc_now(), at, :day) do
      0 -> gettext("today")
      1 -> gettext("yesterday")
      n -> ngettext("%{count} day ago", "%{count} days ago", n)
    end
  end

  defp purge_due(nil, _days), do: gettext("on an unknown date")

  defp purge_due(%DateTime{} = at, days) do
    case days - DateTime.diff(DateTime.utc_now(), at, :day) do
      n when n <= 0 -> gettext("on the next cleanup run")
      1 -> gettext("tomorrow")
      n -> ngettext("in %{count} day", "in %{count} days", n)
    end
  end
end
