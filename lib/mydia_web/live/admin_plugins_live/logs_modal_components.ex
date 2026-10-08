defmodule MydiaWeb.AdminPluginsLive.LogsModalComponents do
  @moduledoc """
  The per-plugin logs modal: activity log, network audit and the Test trigger,
  plus the row formatting they share.
  """
  use MydiaWeb, :html

  @doc """
  Dedicated logs modal: live-tailing activity log, network-request audit, and
  the synthetic-event Test trigger, split across tabs.
  """
  attr :logs, :map, required: true
  attr :log_rows, :any, required: true
  attr :net_rows, :any, required: true

  def logs_modal(assigns) do
    ~H"""
    <.admin_modal
      id="plugin-logs-modal"
      icon="hero-document-text"
      title={"#{@logs.name} logs"}
      size={:lg}
      on_close="close_plugin_logs_modal"
    >
      <div role="tablist" class="tabs tabs-lift">
        <%!-- Activity log tab --%>
        <input
          type="radio"
          name="logs-tabs"
          role="tab"
          class="tab"
          aria-label="Activity"
          id="logs-tab-activity"
          phx-update="ignore"
          checked
        />
        <div role="tabpanel" class="tab-content border-base-300 bg-base-100 p-4">
          <form
            id="log-filter-form"
            phx-change="filter_plugin_logs"
            class="flex items-center gap-2 mb-2"
          >
            <h4 class="font-semibold mr-auto">Activity log</h4>
            <input
              type="search"
              name="query"
              value={@logs.query}
              placeholder="Search messages…"
              phx-debounce="300"
              class="input input-bordered input-xs w-40"
              id="log-search"
            />
            <select name="level" class="select select-bordered select-xs" id="log-level-filter">
              <option
                :for={lvl <- ~w(debug info warn error)}
                value={lvl}
                selected={to_string(@logs.min_level) == lvl}
              >
                {String.capitalize(lvl)}+
              </option>
            </select>
          </form>
          <div
            id="plugin-logs"
            phx-update="stream"
            class="text-xs font-mono space-y-1 max-h-[28rem] overflow-y-auto rounded bg-base-200 p-2"
          >
            <p id="plugin-logs-empty" class="hidden only:block text-base-content/60">
              No activity yet — add media or use Run test to confirm it works.
            </p>
            <div
              :for={{dom_id, log} <- @log_rows}
              id={dom_id}
              class={["flex gap-2 items-baseline", log_row_class(log)]}
            >
              <span class="opacity-40 shrink-0 tabular-nums" title={log_full_time(log.inserted_at)}>
                {log_time(log.inserted_at)}
              </span>
              <span class="opacity-50 shrink-0 w-5" title={to_string(log.source)}>
                {source_tag(log.source)}
              </span>
              <span class="flex-1 break-all">{log.message}</span>
              <span :if={log.test_run} class="badge badge-warning badge-xs shrink-0">test</span>
            </div>
          </div>
        </div>

        <%!-- Network tab --%>
        <input
          type="radio"
          name="logs-tabs"
          role="tab"
          class="tab"
          aria-label="Network"
          id="logs-tab-network"
          phx-update="ignore"
        />
        <div role="tabpanel" class="tab-content border-base-300 bg-base-100 p-4">
          <h4 class="font-semibold mb-2">Network requests</h4>
          <p class="text-xs text-base-content/60 mb-2">
            Every outbound request this plugin made, gated against its
            <code class="text-xs">net:http</code>
            allowlist.
          </p>
          <div class="overflow-x-auto rounded bg-base-200">
            <table class="table table-xs font-mono">
              <thead>
                <tr>
                  <th>Time</th>
                  <th>Method</th>
                  <th>URL</th>
                  <th class="text-right">Status</th>
                  <th class="text-right">Size</th>
                  <th class="text-right">Time</th>
                  <th>Outcome</th>
                </tr>
              </thead>
              <tbody id="plugin-net" phx-update="stream">
                <tr id="plugin-net-empty" class="hidden only:table-row">
                  <td colspan="7" class="text-base-content/60">No recorded requests.</td>
                </tr>
                <.net_row :for={{dom_id, event} <- @net_rows} id={dom_id} event={event} />
              </tbody>
            </table>
          </div>
        </div>

        <%!-- Test tab --%>
        <input
          type="radio"
          name="logs-tabs"
          role="tab"
          class="tab"
          aria-label="Test"
          id="logs-tab-test"
          phx-update="ignore"
        />
        <div role="tabpanel" class="tab-content border-base-300 bg-base-100 p-4">
          <h4 class="font-semibold mb-2">Test</h4>
          <div :if={@logs.enabled and @logs.test_events != []}>
            <form phx-submit="test_plugin" class="flex gap-2 items-center">
              <input type="hidden" name="slug" value={@logs.slug} />
              <select name="event" class="select select-bordered select-sm flex-1" id="test-event">
                <option :for={ev <- @logs.test_events} value={ev}>{ev}</option>
              </select>
              <button id="test-plugin" type="submit" class="btn btn-sm btn-primary">
                Run test
              </button>
            </form>
            <p class="text-xs text-base-content/60 mt-2">
              Fires a synthetic event so you can confirm the plugin works without waiting for real media.
              Watch the Activity tab for the resulting log lines.
            </p>
          </div>
          <p
            :if={not (@logs.enabled and @logs.test_events != [])}
            class="text-sm text-base-content/60"
          >
            <%= cond do %>
              <% not @logs.enabled -> %>
                Enable this plugin to send it a test event.
              <% true -> %>
                This plugin does not subscribe to any events, so there is nothing to test.
            <% end %>
          </p>
        </div>
      </div>

      <:actions>
        <button
          id="close-plugin-logs"
          type="button"
          class="btn btn-ghost btn-sm"
          phx-click="close_plugin_logs_modal"
        >
          Close
        </button>
      </:actions>
    </.admin_modal>
    """
  end

  @doc false
  attr :id, :string, required: true
  attr :event, :map, required: true

  def net_row(assigns) do
    assigns = assign(assigns, :meta, assigns.event.metadata || %{})

    ~H"""
    <tr id={@id} class={net_row_class(@event)}>
      <td class="whitespace-nowrap opacity-60" title={log_full_time(@event.inserted_at)}>
        {log_time(@event.inserted_at)}
      </td>
      <td class="whitespace-nowrap">{@meta["method"] || "GET"}</td>
      <td class="max-w-md truncate" title={@meta["url"]}>{net_path(@meta)}</td>
      <td class="text-right whitespace-nowrap">{@meta["status"] || "—"}</td>
      <td class="text-right whitespace-nowrap">{format_bytes(@meta["bytes"])}</td>
      <td class="text-right whitespace-nowrap">{format_ms(@meta["duration_ms"])}</td>
      <td class="whitespace-nowrap">
        <span class={["badge badge-xs", net_outcome_class(@meta["outcome"])]}>
          {@meta["outcome"] || "—"}
        </span>
      </td>
    </tr>
    """
  end

  # Host + path of the audited URL (query string dropped) so the table reads
  # cleanly; the full URL is available on the cell's title tooltip.
  defp net_path(%{"url" => url}) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host, path: path} when is_binary(host) -> host <> (path || "")
      _ -> url
    end
  end

  defp net_path(meta), do: meta["host"] || "—"

  # Tint a network row by its severity: errors warn, everything else neutral.
  defp net_row_class(%{severity: :warning}), do: "text-warning"
  defp net_row_class(%{severity: :error}), do: "text-error"
  defp net_row_class(_), do: ""

  defp net_outcome_class("ok"), do: "badge-success"
  defp net_outcome_class(nil), do: "badge-ghost"
  defp net_outcome_class(_), do: "badge-error"

  # Human-readable response size. nil/0 render as a dash so a failed request
  # (no body) isn't shown as a misleading "0 B".
  defp format_bytes(bytes) when is_integer(bytes) and bytes > 0 do
    cond do
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1_024 -> "#{Float.round(bytes / 1_024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_bytes(_), do: "—"

  defp format_ms(ms) when is_integer(ms), do: "#{ms}ms"
  defp format_ms(_), do: "—"

  # Activity-log timestamp: compact HH:MM:SS for the row, full UTC on hover.
  defp log_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp log_time(_), do: ""

  defp log_full_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  defp log_full_time(_), do: ""

  # Compact source marker for an activity-log line.
  defp source_tag(:guest), do: "log"
  defp source_tag(:wasi), do: "out"
  defp source_tag(:host), do: "sys"
  defp source_tag(_), do: "?"

  # Level-keyed row tint; error/warn stand out so a trap marker is unmistakable.
  defp log_row_class(%{level: :error}), do: "text-error"
  defp log_row_class(%{level: :warn}), do: "text-warning"
  defp log_row_class(%{level: :debug}), do: "text-base-content/50"
  defp log_row_class(_), do: ""
end
