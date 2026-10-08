defmodule MydiaWeb.AdminPluginsLive.ModalComponents do
  @moduledoc """
  The Plugins page modals: store, capability approval, detail, logs and
  settings. Each is an `<.admin_modal>`; the tab, rows and capability summary
  they share live in `MydiaWeb.AdminPluginsLive.Components`.
  """
  use MydiaWeb, :html

  import MydiaWeb.AdminPluginsLive.Components, only: [capability_summary: 1, catalog_row: 1]
  import MydiaWeb.PluginSetupComponents, only: [settings_field: 1]

  alias MydiaWeb.AdminPluginsLive.CapabilitySummary

  defp empty_catalog_message(%{source_count: count}) when count > 1,
    do: "The plugin store has no plugins yet (checked #{count} sources)."

  defp empty_catalog_message(_), do: "The plugin store has no plugins yet."

  @doc """
  The store modal. It opens on every Browse store click and renders the
  loading, error, empty and populated states inside itself.
  """
  attr :browse, :any,
    required: true,
    doc: "a Mydia.Plugins.Index.BrowseResult, nil while browsing"

  def store_modal(assigns) do
    ~H"""
    <.admin_modal
      id="plugin-store-modal"
      icon="hero-squares-plus"
      title="Plugin store"
      size={:lg}
      on_close="close_plugin_store_modal"
    >
      <div phx-window-keydown="close_plugin_store_modal" phx-key="Escape"></div>

      <div :if={is_nil(@browse)} id="store-loading" class="flex justify-center py-10">
        <span class="loading loading-spinner loading-md"></span>
      </div>

      <div :if={@browse} class="space-y-3">
        <div :if={@browse.error} id="browse-error" class="alert alert-error">
          <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
          <span>
            {@browse.failed_count} of {@browse.source_count} sources could not be loaded: {@browse.error}
          </span>
        </div>

        <div
          :if={is_nil(@browse.error) and @browse.status == :empty}
          id="catalog-empty"
          class="alert alert-info"
        >
          <.icon name="hero-information-circle" class="w-5 h-5" />
          <span>{empty_catalog_message(@browse)}</span>
        </div>

        <div
          :if={@browse.status == :available}
          id="plugin-catalog"
          class="bg-base-200 rounded-box divide-y divide-base-300"
        >
          <.catalog_row :for={item <- @browse.catalog} item={item} />
        </div>
      </div>

      <:actions>
        <button
          id="close-store"
          type="button"
          class="btn btn-ghost"
          phx-click="close_plugin_store_modal"
        >
          Close
        </button>
      </:actions>
    </.admin_modal>
    """
  end

  @doc """
  The capability-approval modal: the emphasized surface.

  Activation is gated behind explicit approval. Capabilities render as one
  grouped, host-owned list (see `capability_summary/1`); on re-approval only the
  widened values are badged. Uses DaisyUI `modal modal-open` markup so the
  element is only present when an approval is in flight.
  """
  attr :approval, :map, required: true

  def approval_modal(assigns) do
    reapproval? = assigns.approval.ungranted != %{}

    summary =
      CapabilitySummary.build(assigns.approval.capabilities,
        new: assigns.approval.ungranted,
        settings_schema: assigns.approval.settings_schema
      )

    assigns =
      assign(assigns,
        reapproval?: reapproval?,
        summary: summary,
        new_count: CapabilitySummary.new_count(summary)
      )

    ~H"""
    <.admin_modal
      id="plugin-approval-modal"
      icon="hero-shield-check"
      title={"#{if(@reapproval?, do: "Re-approve", else: "Approve")} #{@approval.name}"}
      on_close="decline_approval"
    >
      <p :if={not @reapproval?} class="text-sm text-base-content/70">
        It can't run until you approve. Approval is all-or-nothing.
      </p>
      <p :if={@reapproval?} id="approval-reapproval-note" class="text-sm text-base-content/70">
        v{@approval.version} asks for {things(@new_count)} you haven't approved. It keeps
        running on the old grant until you re-approve.
      </p>

      <div
        :if={@approval[:publisher]}
        id="approval-publisher-warning"
        class="alert alert-warning mt-3 text-sm"
      >
        <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
        <span>
          This plugin comes from {@approval.publisher}, not the Mydia plugin index. Mydia has not
          reviewed it; you are trusting whoever holds that source's signing key.
        </span>
      </div>
      <div
        :if={@approval[:replaces]}
        id="approval-replaces"
        class="alert alert-info mt-3 text-sm"
      >
        <.icon name="hero-arrow-path" class="w-5 h-5" />
        <span>
          This replaces {@approval.name} from {@approval.replaces}. Future updates will come from {@approval[
            :publisher
          ] || "the Mydia plugin index"}.
        </span>
      </div>

      <div class="my-4">
        <.capability_summary id="approval-capabilities" summary={@summary} />
      </div>

      <:actions>
        <button
          id="decline-approval"
          type="button"
          class="btn btn-ghost"
          phx-click="decline_approval"
        >
          Decline
        </button>
        <button
          id="confirm-approval"
          type="button"
          class="btn btn-primary"
          phx-click="confirm_approval"
        >
          {if(@reapproval?, do: "Re-approve", else: "Approve & activate")}
        </button>
      </:actions>
    </.admin_modal>
    """
  end

  defp things(1), do: "1 thing"
  defp things(n), do: "#{n} things"

  @doc """
  Per-plugin detail modal: granted capabilities and host grants.

  Operational surfaces (activity log, network requests, Test) live in the
  dedicated `logs_modal/1`, reached via the row's Logs button.
  """
  attr :detail, :map, required: true

  def detail_modal(assigns) do
    assigns =
      assign(assigns,
        granted_summary:
          CapabilitySummary.build(assigns.detail.granted,
            settings_schema: assigns.detail.settings_schema
          ),
        ungranted_summary: CapabilitySummary.build(assigns.detail.ungranted)
      )

    ~H"""
    <.admin_modal
      id="plugin-detail-modal"
      icon="hero-information-circle"
      title={@detail.name}
      on_close="close_plugin_detail_modal"
    >
      <p
        :if={@detail.description}
        id="detail-description"
        class="text-sm text-base-content/70 whitespace-pre-line"
      >
        {@detail.description}
      </p>

      <div class="mt-4">
        <h4 class="font-semibold mb-2">Granted capabilities</h4>
        <.capability_summary
          :if={@detail.granted != %{}}
          id="detail-capabilities"
          summary={@granted_summary}
        />
        <p :if={@detail.granted == %{}} class="text-sm text-base-content/60">
          No capabilities granted.
        </p>
      </div>

      <div :if={@detail.ungranted != %{}} id="detail-ungranted" class="mt-4">
        <h4 class="font-semibold mb-2 flex items-center gap-2 text-warning">
          <.icon name="hero-exclamation-triangle" class="w-4 h-4" /> Requested but not granted
        </h4>
        <.capability_summary id="detail-ungranted-capabilities" summary={@ungranted_summary} />
        <p class="text-xs text-base-content/60 mt-2">
          This version's manifest asks for these. Calls into them are denied until you re-approve
          the plugin from its row.
        </p>
      </div>

      <:actions>
        <button
          id={"detail-logs-#{@detail.slug}"}
          type="button"
          class="btn btn-ghost btn-sm mr-auto"
          phx-click="show_plugin_logs"
          phx-value-slug={@detail.slug}
        >
          <.icon name="hero-document-text" class="w-4 h-4" /> View logs
        </button>
        <button
          id="close-plugin-detail"
          type="button"
          class="btn btn-ghost btn-sm"
          phx-click="close_plugin_detail_modal"
        >
          Close
        </button>
      </:actions>
    </.admin_modal>
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

  @doc """
  The operator settings modal (U3): renders a plugin's manifest-declared
  `settings_schema` as a form. Field inputs are derived from each field's
  declared `type`; secrets are write-only (never echoed back). Saving recomputes
  the host grant from any host-granting URL field (see `Mydia.Plugins.update_settings/2`).
  """
  attr :settings, :map, required: true

  def settings_modal(assigns) do
    ~H"""
    <.admin_modal
      id="plugin-settings-modal"
      icon="hero-cog-6-tooth"
      title={"#{@settings.name} settings"}
      on_close="close_plugin_settings_modal"
    >
      <.form
        :if={@settings.schema != []}
        for={@settings.form}
        id="plugin-settings-form"
        phx-change="validate_plugin_settings"
        phx-submit="save_plugin_settings"
      >
        <input type="hidden" name="slug" value={@settings.slug} />
        <div class="space-y-3 my-4">
          <div
            :for={field <- Enum.filter(@settings.schema, &visible_field?(&1, @settings.values))}
            class="space-y-1"
          >
            <.settings_field
              field={field}
              form={@settings.form}
              disabled={field["key"] in @settings.env_keys}
            />
            <p
              :if={field["key"] in @settings.env_keys}
              id={"settings-env-#{field["key"]}"}
              class="flex items-center gap-2 text-xs text-base-content/60"
            >
              <.config_source_badge source={:env} size="xs" />
              Set in the environment or config file. Change it there.
            </p>
          </div>
        </div>
        <.admin_modal_actions>
          <button
            type="button"
            class="btn btn-ghost"
            phx-click="close_plugin_settings_modal"
          >
            Cancel
          </button>
          <button type="submit" class="btn btn-primary">
            Save settings
          </button>
        </.admin_modal_actions>
      </.form>
      <.ceilings_form :if={@settings.page_writes?} settings={@settings} />
    </.admin_modal>
    """
  end

  @ceiling_options [
    {"Nothing", "none"},
    {"Ask every time", "once"},
    {"Up to a session", "session"},
    {"Up to always", "always"}
  ]

  attr :settings, :map, required: true

  defp ceilings_form(assigns) do
    assigns = assign(assigns, :options, @ceiling_options)

    ~H"""
    <.form
      for={@settings.ceilings_form}
      id="plugin-ceilings-form"
      phx-submit="save_ceilings"
      class="border-t border-base-300 pt-4 space-y-2"
    >
      <input type="hidden" name="slug" value={@settings.slug} />
      <h4 class="font-medium">What each role may allow without asking</h4>
      <.input
        :for={role <- ~w(admin user guest readonly)}
        field={@settings.ceilings_form[role]}
        type="select"
        label={String.capitalize(role)}
        options={@options}
      />
      <div class="flex justify-end">
        <button type="submit" id="save-ceilings" class="btn btn-sm">Save permissions</button>
      </div>
    </.form>
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
end
