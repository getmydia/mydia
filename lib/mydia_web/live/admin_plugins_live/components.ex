defmodule MydiaWeb.AdminPluginsLive.Components do
  @moduledoc """
  Components for the admin plugin store and capability-approval UI (U9).

  The capability labels here are **host-owned**: they are derived from the
  capability *class*, never from author-supplied manifest free-text (KTD6). A
  plugin author cannot influence the words the admin reads when approving — that
  is the whole point of the approval surface.
  """
  use MydiaWeb, :html

  alias Mydia.Plugins.Manifest

  @doc """
  Plain-language description of a single declared capability.

  `class` is the taxonomy class and `values` its declared values (hosts, events,
  namespaces). Always host-authored.
  """
  @spec capability_label(String.t(), [String.t()]) :: String.t()
  def capability_label("net:http", hosts),
    do: "Make network requests to: #{join(hosts)}"

  def capability_label("events:subscribe", events),
    do: "React to these events: #{join(events)}"

  def capability_label("data:read", namespaces),
    do: "Read your library data: #{join(namespaces)}"

  def capability_label("surfaces:write", surfaces),
    do: "Write to these surfaces: #{join(surfaces)}"

  def capability_label("state:kv", _),
    do: "Store its own state across runs"

  def capability_label("users:connections", _),
    do:
      "Read connected users' linked accounts and watch history, and mark items " <>
        "watched on their behalf"

  def capability_label("schedule:interval", _),
    do: "Run automatically on a fixed schedule"

  def capability_label(other, values),
    do: "#{other}: #{join(values)}"

  @doc "The hero icon for a capability class (host-owned)."
  @spec capability_icon(String.t()) :: String.t()
  def capability_icon("net:http"), do: "hero-globe-alt"
  def capability_icon("events:subscribe"), do: "hero-bell-alert"
  def capability_icon("data:read"), do: "hero-book-open"
  def capability_icon("surfaces:write"), do: "hero-pencil-square"
  def capability_icon("state:kv"), do: "hero-circle-stack"
  def capability_icon("users:connections"), do: "hero-users"
  def capability_icon("schedule:interval"), do: "hero-clock"
  def capability_icon(_), do: "hero-key"

  @doc "True when a capability class carries privacy/security weight worth emphasizing."
  @spec sensitive_capability?(String.t()) :: boolean()
  def sensitive_capability?(class),
    do: class in ["net:http", "data:read", "surfaces:write", "users:connections"]

  defp join([]), do: "(none)"
  defp join(values), do: Enum.join(values, ", ")

  @doc """
  One-line, host-owned summary of a capability set, for the row-level warning on
  a plugin whose manifest outgrew its grant. Same vocabulary as
  `capability_label/2` so the row and the approval modal cannot drift apart.
  """
  @spec ungranted_summary(map()) :: String.t()
  def ungranted_summary(capabilities) do
    capabilities
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join("; ", fn {class, values} ->
      capability_label(class, List.wrap(values))
    end)
  end

  @doc """
  Renders the Plugins tab: header, installed summary rows, and the store catalog.

  Each installed plugin renders a compact summary row with provenance and
  lifecycle actions; env-sourced rows render read-only. The catalog lists
  available store entries with an Install action.
  """
  attr :installed, :list, required: true
  attr :catalog, :list, required: true
  attr :updates, :any, required: true
  attr :browse_error, :string, default: nil

  def plugins_tab(assigns) do
    ~H"""
    <div class="p-4 sm:p-6 space-y-4">
      <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
        <div>
          <h2 class="text-lg font-semibold flex items-center gap-2">
            <.icon name="hero-puzzle-piece" class="w-5 h-5 opacity-60" /> Plugins
            <span class="badge badge-ghost">{length(@installed)}</span>
          </h2>
          <p class="text-sm text-base-content/70 mt-1">
            Sandboxed extensions. Each plugin runs with only the capabilities you approve.
          </p>
        </div>
        <.button
          id="browse-store"
          variant="primary"
          class="btn btn-sm btn-primary"
          phx-click="browse_store"
        >
          <.icon name="hero-squares-plus" class="w-4 h-4" /> Browse store
        </.button>
      </div>

      <%!-- Installed plugins --%>
      <div id="plugins-installed" class="space-y-2">
        <div :if={@installed == []} class="alert alert-info">
          <.icon name="hero-information-circle" class="w-5 h-5" />
          <span>No plugins installed yet. Browse the store to add one.</span>
        </div>

        <div :if={@installed != []} class="bg-base-200 rounded-box divide-y divide-base-300">
          <.plugin_row :for={plugin <- @installed} plugin={plugin} updates={@updates} />
        </div>
      </div>

      <%!-- Store catalog --%>
      <div :if={@browse_error} id="browse-error" class="alert alert-error">
        <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
        <span>Could not reach a plugin source: {@browse_error}</span>
      </div>

      <div :if={@catalog != []} id="plugin-catalog" class="space-y-2">
        <h3 class="text-base font-semibold">Available</h3>
        <div class="bg-base-200 rounded-box divide-y divide-base-300">
          <.catalog_row :for={entry <- @catalog} entry={entry} />
        </div>
      </div>
    </div>
    """
  end

  @doc "A compact summary row for one installed plugin (provenance + lifecycle)."
  attr :plugin, :map, required: true
  attr :updates, :any, required: true

  def plugin_row(assigns) do
    ~H"""
    <div
      id={"plugin-row-#{@plugin.slug}"}
      class="flex flex-col sm:flex-row sm:items-center justify-between gap-3 p-3 sm:p-4"
    >
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2 flex-wrap">
          <span class="font-medium truncate">{@plugin.name}</span>
          <span class="text-xs text-base-content/50">v{@plugin.version}</span>
          <.source_badge source={@plugin.source} />
          <span class={[
            "badge badge-sm",
            (@plugin.enabled && "badge-success") || "badge-ghost"
          ]}>
            {if(@plugin.enabled, do: "active", else: "inactive")}
          </span>
          <span
            :if={MapSet.member?(@updates, @plugin.slug)}
            id={"update-badge-#{@plugin.slug}"}
            class="badge badge-sm badge-warning"
          >
            update available
          </span>
          <span
            :if={@plugin.needs_reapproval}
            id={"reapproval-badge-#{@plugin.slug}"}
            class="badge badge-sm badge-warning"
          >
            needs re-approval
          </span>
        </div>
        <p :if={@plugin.network_hosts != []} class="text-xs text-base-content/60 mt-1">
          <.icon name="hero-globe-alt" class="w-3 h-3 inline" />
          Can contact: {Enum.join(@plugin.network_hosts, ", ")}
        </p>
        <p
          :if={@plugin.needs_reapproval}
          id={"reapproval-note-#{@plugin.slug}"}
          class="text-xs text-warning mt-1"
        >
          <.icon name="hero-exclamation-triangle" class="w-3 h-3 inline" />
          This version asks for more than you approved: {ungranted_summary(@plugin.ungranted)}. Those
          calls are denied until you re-approve it.
        </p>
      </div>

      <div class="flex flex-wrap items-center gap-2 shrink-0">
        <span :if={@plugin.read_only} class="text-xs text-base-content/50">
          configured via env
        </span>

        <.button
          :if={not @plugin.read_only and (@plugin.pending_approval or @plugin.needs_reapproval)}
          id={"approve-#{@plugin.slug}"}
          class="btn btn-warning btn-sm"
          phx-click="review_approve"
          phx-value-slug={@plugin.slug}
        >
          {if(@plugin.needs_reapproval, do: "Review & re-approve", else: "Review & approve")}
        </.button>

        <%!-- Always show the Settings button so its absence is never silently
              confusing; when it can't open it renders disabled with a reason. --%>
        <.settings_button :if={@plugin.read_only or @plugin.pending_approval} plugin={@plugin} />

        <div :if={not @plugin.read_only and not @plugin.pending_approval} class="join">
          <.button
            id={"toggle-#{@plugin.slug}"}
            class="btn btn-ghost btn-sm join-item"
            phx-click="toggle_enabled"
            phx-value-slug={@plugin.slug}
          >
            {if(@plugin.enabled, do: "Disable", else: "Enable")}
          </.button>
          <.settings_button plugin={@plugin} />
          <.button
            id={"details-#{@plugin.slug}"}
            class="btn btn-ghost btn-sm join-item"
            phx-click="show_detail"
            phx-value-slug={@plugin.slug}
          >
            Details
          </.button>
          <.button
            id={"logs-#{@plugin.slug}"}
            class="btn btn-ghost btn-sm join-item"
            phx-click="show_logs"
            phx-value-slug={@plugin.slug}
          >
            Logs
          </.button>
          <.button
            id={"remove-#{@plugin.slug}"}
            class="btn btn-ghost btn-sm join-item text-error"
            phx-click="remove"
            phx-value-slug={@plugin.slug}
            data-confirm={"Remove #{@plugin.name}?"}
          >
            <.icon name="hero-trash" class="w-4 h-4" />
          </.button>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  The per-plugin Settings button.

  Always rendered so its absence is never silently confusing. When the plugin's
  settings can't be edited (env-sourced, awaiting approval, or no configurable
  schema) it renders disabled inside a tooltip that explains why.
  """
  attr :plugin, :map, required: true

  def settings_button(assigns) do
    assigns = assign(assigns, :reason, settings_disabled_reason(assigns.plugin))

    ~H"""
    <div :if={@reason} class="tooltip tooltip-left join-item" data-tip={@reason}>
      <.button
        id={"settings-#{@plugin.slug}"}
        class="btn btn-ghost btn-sm join-item"
        disabled
      >
        Settings
      </.button>
    </div>
    <.button
      :if={!@reason}
      id={"settings-#{@plugin.slug}"}
      class="btn btn-ghost btn-sm join-item"
      phx-click="edit_settings"
      phx-value-slug={@plugin.slug}
    >
      Settings
    </.button>
    """
  end

  # Why the Settings button can't open, or nil when it can. Precedence matters:
  # an env-sourced row is read-only regardless of approval or schema.
  defp settings_disabled_reason(%{read_only: true}),
    do: "Configured via environment variables; edit those to change settings"

  defp settings_disabled_reason(%{pending_approval: true}),
    do: "Approve this plugin before editing its settings"

  defp settings_disabled_reason(%{has_settings: false}),
    do: "This plugin has no configurable settings"

  defp settings_disabled_reason(_plugin), do: nil

  @doc "A compact summary row for one store catalog entry."
  attr :entry, :map, required: true

  def catalog_row(assigns) do
    ~H"""
    <div
      id={"catalog-row-#{@entry.slug}"}
      class="flex flex-col sm:flex-row sm:items-center justify-between gap-3 p-3 sm:p-4"
    >
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2">
          <span class="font-medium">{@entry.name}</span>
          <span class="text-xs text-base-content/50">v{@entry.version}</span>
        </div>
        <p :if={@entry.description} class="text-sm text-base-content/70 truncate">
          {@entry.description}
        </p>
      </div>
      <.button
        id={"install-#{@entry.slug}"}
        variant="primary"
        class="btn btn-primary btn-sm"
        phx-click="review_install"
        phx-value-slug={@entry.slug}
      >
        Install
      </.button>
    </div>
    """
  end

  @doc """
  The capability-approval modal: the emphasized surface.

  Activation is gated behind explicit approval. Capabilities render in
  host-owned plain language (see `capability_list/1`); the network destination
  is made legible. Uses DaisyUI `modal modal-open` markup so the element is only
  present when an approval is in flight.
  """
  attr :approval, :map, required: true

  def approval_modal(assigns) do
    ~H"""
    <div id="approval-modal" class="modal modal-open">
      <div class="modal-box max-w-lg">
        <h3 class="text-lg font-bold flex items-center gap-2">
          <.icon name="hero-shield-check" class="w-5 h-5" />
          {if(@approval.ungranted == %{}, do: "Approve", else: "Re-approve")} {@approval.name}
        </h3>
        <p :if={@approval.ungranted == %{}} class="text-sm text-base-content/70 mt-1">
          {@approval.name} (v{@approval.version}) is requesting the capabilities below.
          It cannot run until you approve them. Approval is all-or-nothing.
        </p>
        <p :if={@approval.ungranted != %{}} class="text-sm text-base-content/70 mt-1">
          {@approval.name} (v{@approval.version}) now requests more than you approved. It keeps
          running on the older grant, and calls into anything new are denied until you re-approve.
          Approval is all-or-nothing.
        </p>

        <div class="my-4 space-y-2">
          <div
            :if={@approval.ungranted != %{}}
            id="approval-new-capabilities"
            class="rounded-lg p-3 bg-warning/10 space-y-2"
          >
            <p class="font-medium flex items-center gap-2">
              <.icon name="hero-exclamation-triangle" class="w-5 h-5 shrink-0" />
              New since you last approved
            </p>
            <.capability_list id="approval-ungranted" capabilities={@approval.ungranted} />
          </div>

          <p :if={@approval.ungranted != %{}} class="text-sm font-medium">
            Everything this plugin will be granted:
          </p>
          <.capability_list id="approval-capabilities" capabilities={@approval.capabilities} />
          <.host_grant_note id="approval-host-grant" settings_schema={@approval.settings_schema} />
        </div>

        <div class="modal-action">
          <.button id="decline-approval" class="btn btn-ghost" phx-click="decline_approval">
            Decline
          </.button>
          <.button
            id="confirm-approval"
            variant="primary"
            class="btn btn-primary"
            phx-click="confirm_approval"
          >
            Approve &amp; activate
          </.button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="decline_approval"></div>
    </div>
    """
  end

  @doc """
  Per-plugin detail modal: granted capabilities + host grants + Revoke.

  Operational surfaces (activity log, network requests, Test) live in the
  dedicated `logs_modal/1`, reached via the row's Logs button.
  """
  attr :detail, :map, required: true

  def detail_modal(assigns) do
    ~H"""
    <div id="detail-modal" class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <h3 class="text-lg font-bold">{@detail.name}</h3>

        <div class="mt-4">
          <h4 class="font-semibold mb-2">Granted capabilities</h4>
          <.capability_list
            :if={@detail.granted != %{}}
            id="detail-capabilities"
            capabilities={@detail.granted}
          />
          <p :if={@detail.granted == %{}} class="text-sm text-base-content/60">
            No capabilities granted.
          </p>
          <.host_grant_note id="detail-host-grant" settings_schema={@detail.settings_schema} />
        </div>

        <div :if={@detail.ungranted != %{}} id="detail-ungranted" class="mt-4">
          <h4 class="font-semibold mb-2 flex items-center gap-2 text-warning">
            <.icon name="hero-exclamation-triangle" class="w-4 h-4" /> Requested but not granted
          </h4>
          <.capability_list id="detail-ungranted-capabilities" capabilities={@detail.ungranted} />
          <p class="text-xs text-base-content/60 mt-2">
            This version's manifest asks for these. Calls into them are denied until you re-approve
            the plugin from its row.
          </p>
        </div>

        <div class="modal-action">
          <.button
            id={"detail-logs-#{@detail.slug}"}
            class="btn btn-ghost btn-sm mr-auto"
            phx-click="show_logs"
            phx-value-slug={@detail.slug}
          >
            <.icon name="hero-document-text" class="w-4 h-4" /> View logs
          </.button>
          <.button
            id={"detail-revoke-#{@detail.slug}"}
            class="btn btn-warning btn-sm"
            phx-click="revoke"
            phx-value-slug={@detail.slug}
            data-confirm="Revoke all capabilities and deactivate this plugin?"
          >
            Revoke capabilities
          </.button>
          <.button class="btn btn-ghost btn-sm" phx-click="close_detail">
            Close
          </.button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="close_detail"></div>
    </div>
    """
  end

  @doc """
  Dedicated logs modal: live-tailing activity log, network-request audit, and
  the synthetic-event Test trigger, split across tabs.
  """
  attr :logs, :map, required: true
  attr :log_rows, :any, required: true
  attr :net_rows, :any, required: true

  def logs_modal(assigns) do
    ~H"""
    <div id="logs-modal" class="modal modal-open">
      <div class="modal-box max-w-4xl">
        <h3 class="text-lg font-bold flex items-center gap-2">
          <.icon name="hero-document-text" class="w-5 h-5" /> {@logs.name} — logs
        </h3>

        <div role="tablist" class="tabs tabs-lift mt-4">
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
            <form id="log-filter-form" phx-change="filter_logs" class="flex items-center gap-2 mb-2">
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
                <.button id="test-plugin" type="submit" class="btn btn-sm btn-primary">
                  Run test
                </.button>
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

        <div class="modal-action">
          <.button class="btn btn-ghost btn-sm" phx-click="close_logs">
            Close
          </.button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="close_logs"></div>
    </div>
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

  @doc """
  The operator settings modal (U3): renders a plugin's manifest-declared
  `settings_schema` as a form. Field inputs are derived from each field's
  declared `type`; secrets are write-only (never echoed back). Saving recomputes
  the host grant from any host-granting URL field (see `Mydia.Plugins.update_settings/2`).
  """
  attr :settings, :map, required: true

  def settings_modal(assigns) do
    ~H"""
    <div id="settings-modal" class="modal modal-open">
      <div class="modal-box max-w-lg">
        <h3 class="text-lg font-bold flex items-center gap-2">
          <.icon name="hero-cog-6-tooth" class="w-5 h-5" /> {@settings.name} settings
        </h3>
        <.form
          for={@settings.form}
          id="plugin-settings-form"
          phx-change="settings_changed"
          phx-submit="save_settings"
        >
          <input type="hidden" name="slug" value={@settings.slug} />
          <div class="space-y-3 my-4">
            <.settings_field
              :for={field <- Enum.filter(@settings.schema, &visible_field?(&1, @settings.values))}
              field={field}
              form={@settings.form}
            />
          </div>
          <div class="modal-action">
            <.button type="button" class="btn btn-ghost" phx-click="close_settings">
              Cancel
            </.button>
            <.button type="submit" variant="primary" class="btn btn-primary">
              Save settings
            </.button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop" phx-click="close_settings"></div>
    </div>
    """
  end

  # Renders one settings field from its declared type.
  attr :field, :map, required: true
  attr :form, :any, required: true

  defp settings_field(%{field: %{"type" => "enum"}} = assigns) do
    ~H"""
    <.input
      field={@form[@field["key"]]}
      type="select"
      label={@field["label"] || @field["key"]}
      options={@field["options"] || []}
    />
    """
  end

  defp settings_field(%{field: %{"type" => "secret"}} = assigns) do
    ~H"""
    <.input
      field={@form[@field["key"]]}
      type="password"
      autocomplete="off"
      label={@field["label"] || @field["key"]}
      placeholder="••••••••"
    />
    """
  end

  defp settings_field(%{field: %{"type" => "url"}} = assigns) do
    ~H"""
    <.input field={@form[@field["key"]]} type="url" label={@field["label"] || @field["key"]} />
    """
  end

  defp settings_field(%{field: %{"type" => "text"}} = assigns) do
    ~H"""
    <.input
      field={@form[@field["key"]]}
      type="textarea"
      label={@field["label"] || @field["key"]}
    />
    """
  end

  defp settings_field(assigns) do
    ~H"""
    <.input field={@form[@field["key"]]} type="text" label={@field["label"] || @field["key"]} />
    """
  end

  # A field is shown unless its `visible_when` map names controlling keys whose
  # current values don't all match. Each value may be a string or list of
  # acceptable strings. Fields without `visible_when` are always shown.
  defp visible_field?(field, values) do
    case Map.get(field, "visible_when") do
      map when is_map(map) ->
        Enum.all?(map, fn {key, allowed} ->
          to_string(Map.get(values, key, "")) in List.wrap(allowed)
        end)

      _ ->
        true
    end
  end

  @doc """
  Notes that the plugin will reach the host of whatever URL the operator enters
  in its host-granting settings (U4). Renders nothing when the plugin declares no
  host-granting field. Keeps approval consent legible: static hosts come from
  `capability_list`, operator-chosen hosts are disclosed here.
  """
  attr :settings_schema, :list, default: []
  attr :id, :string, required: true

  def host_grant_note(assigns) do
    assigns = assign(assigns, :fields, host_granting_labels(assigns.settings_schema))

    ~H"""
    <div
      :if={@fields != []}
      id={@id}
      class="flex items-start gap-3 rounded-lg p-3 bg-warning/10"
    >
      <.icon name="hero-globe-alt" class="w-5 h-5 mt-0.5 shrink-0" />
      <div>
        <p class="font-medium">Plus any host you enter in: {Enum.join(@fields, ", ")}</p>
        <p class="text-xs text-base-content/60">
          This plugin reaches the server at the URL you configure in these settings.
        </p>
      </div>
    </div>
    """
  end

  # Labels of the host-granting fields, derived from the single source of truth
  # in Mydia.Plugins.Manifest so this disclosure can't drift from the grant logic.
  defp host_granting_labels(schema) do
    schema
    |> Manifest.host_granting_fields()
    |> Enum.map(&(Map.get(&1, "label") || Map.get(&1, "key")))
  end

  @doc """
  Renders the ordered list of declared capabilities for an approval surface.

  `capabilities` is the manifest map `%{class => values}`.
  """
  attr :capabilities, :map, required: true
  attr :id, :string, required: true

  def capability_list(assigns) do
    ~H"""
    <ul id={@id} class="space-y-2">
      <li
        :for={{class, values} <- Enum.sort_by(@capabilities, &elem(&1, 0))}
        id={"#{@id}-#{dom_slug(class)}"}
        class={[
          "flex items-start gap-3 rounded-lg p-3",
          (sensitive_capability?(class) && "bg-warning/10") || "bg-base-200"
        ]}
      >
        <.icon name={capability_icon(class)} class="w-5 h-5 mt-0.5 shrink-0" />
        <div>
          <p class="font-medium">{capability_label(class, List.wrap(values))}</p>
          <p :if={sensitive_capability?(class)} class="text-xs text-base-content/60">
            Review this carefully. It grants access beyond Mydia.
          </p>
        </div>
      </li>
    </ul>
    """
  end

  @doc "A small source-provenance badge (env/index/db)."
  attr :source, :atom, required: true

  def source_badge(assigns) do
    {label, cls} =
      case assigns.source do
        :env -> {"env", "badge-info"}
        :index -> {"index", "badge-ghost"}
        _ -> {"db", "badge-ghost"}
      end

    assigns = assign(assigns, label: label, cls: cls)

    ~H"""
    <span class={["badge badge-sm", @cls]}>{@label}</span>
    """
  end

  defp dom_slug(class), do: String.replace(class, ~r/[^a-z0-9]+/, "-")
end
