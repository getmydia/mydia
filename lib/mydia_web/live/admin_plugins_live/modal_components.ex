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
      <%!-- admin_modal has no keydown hook of its own; this keeps Escape closing the store. --%>
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
  widened values are badged. Built on `admin_modal/1`; the page renders it only
  while an approval is in flight.
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
