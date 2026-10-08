defmodule MydiaWeb.AdminReleaseBlacklistLive.Components do
  @moduledoc false
  use MydiaWeb, :html

  alias Mydia.Downloads.Client.FailureCategory

  attr :rows, :list, required: true
  attr :total_count, :integer, required: true
  attr :page, :integer, required: true
  attr :page_size, :integer, required: true
  attr :failure_reasons, :list, required: true
  attr :failure_reason_filter, :any, required: true

  def blacklist_tab(assigns) do
    ~H"""
    <div class="p-4 sm:p-6 space-y-4">
      <p id="blacklist-ttl-note" class="text-sm text-base-content/70">
        Releases that failed to download are temporarily blocked so the next search avoids them.
        Default TTL is 30 days. Use "Block Forever" to make a block permanent, or "Remove" to lift it immediately.
      </p>

      <div class="flex flex-col md:flex-row md:items-end gap-4">
        <form
          id="blacklist-filter-form"
          phx-change="filter_blacklist"
          class="flex flex-col sm:flex-row gap-2 sm:items-end flex-1"
        >
          <label class="form-control w-full sm:max-w-xs">
            <span class="label label-text">Failure reason</span>
            <select
              name="failure_reason"
              id="failure-reason-filter"
              class="select select-bordered"
            >
              <option value="">All</option>
              <%= for reason <- @failure_reasons do %>
                <option value={reason} selected={reason == @failure_reason_filter}>
                  {reason_label(reason)}
                </option>
              <% end %>
            </select>
          </label>
          <%= if @failure_reason_filter != "" do %>
            <button
              type="button"
              id="clear-filter-btn"
              class="btn btn-ghost btn-sm"
              phx-click="clear_blacklist_filter"
            >
              Clear filter
            </button>
          <% end %>
        </form>
        <div class="text-sm text-base-content/70">
          Showing {length(@rows)} of {@total_count} row{(@total_count == 1 && "") || "s"}
        </div>
      </div>

      <.admin_table id="blacklist" rows={@rows} row_id={&"blacklist-row-#{&1.id}"}>
        <:col :let={row} label="Title" class="font-mono text-xs max-w-md truncate">
          <span title={row.title}>{row.title}</span>
        </:col>
        <:col :let={row} label="Indexer">{row.indexer}</:col>
        <:col :let={row} label="GUID" class="font-mono text-xs max-w-xs truncate">
          <span title={row.guid}>{row.guid}</span>
        </:col>
        <:col :let={row} label="Reason">
          <span class="badge badge-warning badge-sm" title={row.failure_reason}>
            {reason_label(row.failure_reason)}
          </span>
        </:col>
        <:col :let={row} label="Added" class="text-xs">{format_datetime(row.inserted_at)}</:col>
        <:col :let={row} label="Expires" class="text-xs">
          <span class={[
            row.expires_at == nil && "badge badge-error badge-sm",
            row.expires_at != nil && "text-base-content/80"
          ]}>
            {expires_label(row.expires_at)}
          </span>
        </:col>
        <:action :let={row}>
          <.row_action
            :if={row.expires_at}
            id={"block-forever-#{row.id}"}
            icon="hero-lock-closed"
            title="Block forever"
            phx-click="block_blacklist_entry_forever"
            phx-value-id={row.id}
            data-confirm="Block this release forever?"
          />
          <.row_action
            id={"remove-#{row.id}"}
            icon="hero-trash"
            title="Remove"
            destructive
            phx-click="remove_blacklist_entry"
            phx-value-id={row.id}
            data-confirm="Remove this release from the blacklist?"
          />
        </:action>
        <:empty>No releases are currently blacklisted.</:empty>
      </.admin_table>

      <%= if @total_count > @page_size do %>
        <div class="flex items-center justify-between">
          <button
            type="button"
            id="prev-page-btn"
            class="btn btn-sm btn-ghost"
            phx-click="prev_blacklist_page"
            disabled={@page <= 1}
          >
            <.icon name="hero-chevron-left" class="w-4 h-4" /> Previous
          </button>
          <span class="text-sm text-base-content/70">
            Page {@page} of {total_pages(@total_count, @page_size)}
          </span>
          <button
            type="button"
            id="next-page-btn"
            class="btn btn-sm btn-ghost"
            phx-click="next_blacklist_page"
            disabled={@page >= total_pages(@total_count, @page_size)}
          >
            Next <.icon name="hero-chevron-right" class="w-4 h-4" />
          </button>
        </div>
      <% end %>
    </div>
    """
  end

  defp format_datetime(nil), do: "never"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  end

  defp expires_label(nil), do: "forever"

  defp expires_label(%DateTime{} = dt) do
    now = DateTime.utc_now()

    if DateTime.compare(dt, now) == :lt do
      "expired"
    else
      format_datetime(dt)
    end
  end

  defp total_pages(0, _page_size), do: 1
  defp total_pages(total, page_size), do: max(1, ceil(total / page_size))

  # Slugs are stable identifiers; the operator reads the label. Unknown
  # slugs (rows written by a newer version) humanize rather than raise.
  defp reason_label(slug), do: FailureCategory.label(slug)
end
