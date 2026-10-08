defmodule MydiaWeb.AdminPluginsLive.Components do
  @moduledoc """
  Components for the admin plugin store and capability-approval UI (U9).

  Capability wording is **host-owned** and lives in
  `MydiaWeb.AdminPluginsLive.CapabilitySummary`, never in manifest free text
  (KTD6). A plugin author cannot influence the words the admin reads when
  approving; that is the whole point of the approval surface.
  """
  use MydiaWeb, :html

  alias MydiaWeb.AdminPluginsLive.CapabilitySummary

  @doc """
  One-line, host-owned summary of a capability set, for the row-level warning on
  a plugin whose manifest outgrew its grant. Built from `CapabilitySummary` so
  the row and the approval modal cannot drift apart.
  """
  @spec ungranted_summary(map()) :: String.t()
  def ungranted_summary(capabilities),
    do: capabilities |> CapabilitySummary.flat_labels() |> Enum.join(", ")

  # Below this a two-line clamp never hides anything, so no toggle is shown.
  @description_toggle_chars 120

  @doc """
  A plugin's description, clamped to two lines with a client-side More/Less
  toggle when it is long enough to be clipped. Renders nothing without text.
  The text is manifest free text, so HEEx escapes it like any other value.
  """
  attr :id, :string, required: true
  attr :text, :string, default: nil

  def plugin_description(assigns) do
    assigns =
      assign(
        assigns,
        :toggle?,
        is_binary(assigns.text) and String.length(assigns.text) > @description_toggle_chars
      )

    ~H"""
    <div :if={is_binary(@text) and @text != ""} id={@id} class="text-sm text-base-content/70">
      <p id={"#{@id}-text"} class="line-clamp-2 whitespace-pre-line">{@text}</p>
      <button
        :if={@toggle?}
        type="button"
        id={"#{@id}-toggle"}
        class="link link-hover text-xs"
        phx-click={
          JS.toggle_class("line-clamp-2", to: "##{@id}-text")
          |> JS.toggle(to: "##{@id}-toggle > span", display: "inline")
        }
      >
        <span>More</span><span class="hidden">Less</span>
      </button>
    </div>
    """
  end

  @doc """
  Renders the Plugins tab: the intro line and one compact summary row per
  installed plugin, with provenance and lifecycle actions. The store lives in
  `store_modal/1`.
  """
  attr :installed, :list, required: true
  attr :updates, :any, required: true

  def plugins_tab(assigns) do
    ~H"""
    <div class="p-4 sm:p-6 space-y-4">
      <p class="text-sm text-base-content/70">
        Each plugin runs with only the capabilities you approve.
      </p>

      <div id="plugins-installed">
        <.admin_list id="plugins-list" items={@installed}>
          <:row :let={plugin}>
            <.plugin_row plugin={plugin} updates={@updates} />
          </:row>
          <:empty>No plugins installed yet. Browse the store to add one.</:empty>
        </.admin_list>
      </div>

      <.live_component
        module={MydiaWeb.AdminPluginsLive.SourcesComponent}
        id="plugin-sources-card"
      />
    </div>
    """
  end

  @doc "The page header's Browse store button; disabled with a spinner while browsing."
  attr :browsing?, :boolean, default: false

  def header_actions(assigns) do
    ~H"""
    <button
      id="browse-store"
      type="button"
      class="btn btn-sm btn-primary"
      phx-click="open_plugin_store"
      disabled={@browsing?}
    >
      <span :if={@browsing?} class="loading loading-spinner loading-xs"></span>
      <.icon :if={!@browsing?} name="hero-squares-plus" class="w-4 h-4" /> Browse store
    </button>
    """
  end

  @shelf_error_max 160

  # The error text comes from the plugin, so it is clipped here; HEEx escapes it.
  defp shelf_failure_text(%{failing: failing, last_error: error}) do
    who = if failing == 1, do: "1 person", else: "#{failing} people"
    text = "Suggestions failing for #{who}"

    case error |> to_string() |> String.trim() do
      "" -> text
      message when byte_size(message) <= @shelf_error_max -> "#{text}: #{message}"
      message -> "#{text}: #{String.slice(message, 0, @shelf_error_max)}..."
    end
  end

  @doc "A compact summary row for one installed plugin (provenance + lifecycle)."
  attr :plugin, :map, required: true
  attr :updates, :any, required: true

  def plugin_row(assigns) do
    ~H"""
    <.admin_row id={"plugin-row-#{@plugin.slug}"}>
      <:title>
        <span class="truncate">{@plugin.name}</span>
        <span class="text-xs font-normal text-base-content/50">v{@plugin.version}</span>
      </:title>
      <:descriptor>
        <div class="whitespace-normal">
          <.plugin_description id={"plugin-description-#{@plugin.slug}"} text={@plugin.description} />
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
          <p
            :if={@plugin.shelf_failures.failing > 0}
            id={"shelf-failure-note-#{@plugin.slug}"}
            class="text-xs text-warning mt-1"
          >
            <.icon name="hero-exclamation-triangle" class="w-3 h-3 inline" />
            {shelf_failure_text(@plugin.shelf_failures)}
          </p>
          <ul
            :if={@plugin.multi_instance}
            id={"plugin-instances-#{@plugin.slug}"}
            class="text-xs text-base-content/70 mt-1 space-y-0.5"
          >
            <li :if={@plugin.instances == []}>No instances configured yet.</li>
            <li :for={instance <- @plugin.instances} class="flex items-center gap-1">
              <span class={[
                "inline-block w-1.5 h-1.5 rounded-full",
                if(instance.enabled, do: "bg-success", else: "bg-base-content/30")
              ]}></span>
              {instance.name}
            </li>
          </ul>
        </div>
      </:descriptor>
      <:badges>
        <.source_badge
          id={"origin-badge-#{@plugin.slug}"}
          origin={@plugin.origin}
          source_name={@plugin.source_name}
        />
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
      </:badges>
      <:actions>
        <.row_actions>
          <.row_action
            :if={@plugin.pending_approval or @plugin.needs_reapproval}
            id={"approve-#{@plugin.slug}"}
            icon="hero-shield-check"
            title={if(@plugin.needs_reapproval, do: "Review & re-approve", else: "Review & approve")}
            phx-click="review_approve"
            phx-value-slug={@plugin.slug}
          />
          <.row_action
            :if={not @plugin.pending_approval}
            id={"toggle-#{@plugin.slug}"}
            icon="hero-power"
            title={if(@plugin.enabled, do: "Disable", else: "Enable")}
            phx-click="toggle_plugin"
            phx-value-slug={@plugin.slug}
          />
          <%!-- Always show the Settings action so its absence is never silently
                confusing; when it can't open it renders disabled with a reason. --%>
          <.settings_button plugin={@plugin} />
          <.row_action
            :if={not @plugin.pending_approval}
            id={"details-#{@plugin.slug}"}
            icon="hero-information-circle"
            title="Details"
            phx-click="show_plugin_detail"
            phx-value-slug={@plugin.slug}
          />
          <.row_action
            :if={not @plugin.pending_approval}
            id={"logs-#{@plugin.slug}"}
            icon="hero-document-text"
            title="Logs"
            phx-click="show_plugin_logs"
            phx-value-slug={@plugin.slug}
          />
          <%!-- A plugin awaiting approval must stay removable. --%>
          <.row_action
            :if={@plugin.removable}
            id={"remove-#{@plugin.slug}"}
            icon="hero-trash"
            title="Remove"
            destructive
            phx-click="remove_plugin"
            phx-value-slug={@plugin.slug}
            data-confirm={remove_confirm(@plugin)}
          />
        </.row_actions>
      </:actions>
    </.admin_row>
    """
  end

  @doc false
  # The Remove confirm names what is deleted with the plugin, so removing is
  # never mistaken for disabling.
  def remove_confirm(plugin) do
    "Remove #{plugin.name}? This also deletes its settings, approvals and suggestions" <>
      servers_suffix(plugin) <> "."
  end

  defp servers_suffix(%{multi_instance: true, instances: [_]}), do: ", plus 1 configured server"

  defp servers_suffix(%{multi_instance: true, instances: [_ | _] = instances}),
    do: ", plus #{length(instances)} configured servers"

  defp servers_suffix(_plugin), do: ""

  @doc """
  The per-plugin Settings button.

  Always rendered so its absence is never silently confusing. When the plugin's
  settings can't be edited (awaiting approval, or no configurable
  schema) it renders disabled inside a tooltip that explains why.
  """
  attr :plugin, :map, required: true

  def settings_button(assigns) do
    assigns = assign(assigns, :reason, settings_disabled_reason(assigns.plugin))

    ~H"""
    <.row_action
      id={"settings-#{@plugin.slug}"}
      icon="hero-cog-6-tooth"
      title="Settings"
      disabled={@reason != nil}
      disabled_reason={@reason}
      phx-click={if(is_nil(@reason), do: "edit_plugin_settings")}
      phx-value-slug={@plugin.slug}
    />
    """
  end

  # Why the Settings button can't open, or nil when it can.
  defp settings_disabled_reason(%{pending_approval: true}),
    do: "Approve this plugin before editing its settings"

  defp settings_disabled_reason(%{multi_instance: true, has_settings: false}),
    do: "Configured per server on Media servers"

  defp settings_disabled_reason(%{has_settings: false}),
    do: "This plugin has no configurable settings"

  defp settings_disabled_reason(_plugin), do: nil

  @doc "One store entry with the action its install state allows."
  attr :item, Mydia.Plugins.Index.CatalogItem, required: true

  def catalog_row(assigns) do
    assigns = assign(assigns, :key, catalog_key(assigns.item.entry))

    ~H"""
    <div
      id={"catalog-row-#{@key}"}
      class="flex flex-col sm:flex-row sm:items-center justify-between gap-3 p-3 sm:p-4"
    >
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2 flex-wrap">
          <span class="font-medium">{@item.entry.name}</span>
          <span class="text-xs text-base-content/50">v{@item.entry.version}</span>
          <span
            :if={@item.installed_version && @item.installed_version != @item.entry.version}
            class="text-xs text-base-content/50"
          >
            (installed v{@item.installed_version})
          </span>
          <span
            :if={@item.entry.source_id}
            id={"catalog-third-party-#{@key}"}
            class="badge badge-sm badge-warning badge-outline max-w-full truncate"
          >
            Third-party · {@item.entry.source_name}
          </span>
        </div>
        <.plugin_description id={"catalog-description-#{@key}"} text={@item.entry.description} />
        <p :if={@item.state == :other_source} class="text-xs text-base-content/60">
          Installed from {@item.installed_from}
        </p>
      </div>
      <span
        :if={@item.state in [:installed, :bundled]}
        id={"catalog-state-#{@key}"}
        class="badge badge-sm badge-ghost"
      >
        {if(@item.state == :bundled, do: "Bundled", else: "Installed")}
      </span>
      <button
        :if={@item.state in [:not_installed, :update, :replace, :other_source]}
        id={"install-#{@key}"}
        type="button"
        class="btn btn-primary btn-sm"
        phx-click="review_install"
        phx-value-key={@key}
      >
        {install_label(@item)}
      </button>
    </div>
    """
  end

  @doc """
  DOM-safe key for a catalog entry. Official and third-party keys live in
  disjoint namespaces (`official-` and `src-<uuid>-`, the uuid always 36
  characters), so no slug, whatever it contains, can make one entry's key equal
  another's and send a click to the wrong install.
  """
  def catalog_key(%{source_id: nil, slug: slug}), do: "official-#{slug}"
  def catalog_key(%{source_id: id, slug: slug}), do: "src-#{id}-#{slug}"

  defp install_label(%{state: :other_source}), do: "Replace"
  defp install_label(%{state: :update, entry: entry}), do: "Update to v#{entry.version}"
  defp install_label(%{state: :replace}), do: "Install store version"
  defp install_label(_item), do: "Install"

  @doc """
  Renders a `CapabilitySummary`: one block per non-empty group (only Talks to is
  tinted), then a muted "Also:" sentence for background mechanics. Lines new
  since the last approval carry `data-new` and a New badge.
  """
  attr :id, :string, required: true
  attr :summary, CapabilitySummary, required: true

  def capability_summary(assigns) do
    ~H"""
    <div id={@id} class="space-y-3">
      <section
        :for={group <- @summary.groups}
        id={"#{@id}-group-#{group.key}"}
        class={[
          "rounded-lg p-3",
          if(group.emphasized?, do: "bg-warning/10", else: "bg-base-200")
        ]}
      >
        <h4 class="text-sm font-semibold flex items-center gap-2">
          <.icon name={group_icon(group.key)} class="w-4 h-4 shrink-0" />
          {group.title}
        </h4>
        <ul class="mt-1 ml-6 space-y-0.5 text-sm">
          <li
            :for={line <- group.lines}
            class="flex items-center gap-2"
            data-new={line.new? && "true"}
          >
            <span>{line.label}</span>
            <span :if={line.new?} class="badge badge-warning badge-sm">New</span>
          </li>
        </ul>
      </section>
      <p :if={@summary.also != []} id={"#{@id}-also"} class="text-xs text-base-content/60">
        Also:
        <%= for {line, index} <- Enum.with_index(@summary.also) do %>
          <span data-new={line.new? && "true"}>{line.label}<span :if={line.new?} class="text-warning font-medium"> (new)</span></span>{also_separator(
            index,
            length(@summary.also)
          )}
        <% end %>
      </p>
    </div>
    """
  end

  defp also_separator(index, count) when index == count - 1, do: "."
  defp also_separator(_index, _count), do: ","

  defp group_icon(:talks_to), do: "hero-globe-alt"
  defp group_icon(:can_see), do: "hero-eye"
  defp group_icon(:can_change), do: "hero-pencil-square"
  defp group_icon(:adds), do: "hero-squares-plus"

  @doc "Where an installed plugin came from, as a small badge."
  attr :id, :string, required: true
  attr :origin, :any, required: true
  attr :source_name, :string, default: nil

  def source_badge(assigns) do
    {label, cls} = origin_badge(assigns.origin, assigns.source_name)
    assigns = assign(assigns, label: label, cls: cls)

    ~H"""
    <span id={@id} class={["badge badge-sm max-w-full truncate", @cls]}>{@label}</span>
    """
  end

  defp origin_badge(:bundled, _name), do: {"Bundled", "badge-ghost"}
  defp origin_badge(:official, _name), do: {"Mydia store", "badge-ghost"}
  defp origin_badge(:sideloaded, _name), do: {"Sideloaded", "badge-ghost"}

  defp origin_badge({:source, _id}, name),
    do: {"Third-party · #{name}", "badge-warning badge-outline"}

  defp origin_badge(:unknown, _name), do: {"Unknown source", "badge-ghost"}
  defp origin_badge(_removed, _name), do: {"Source removed", "badge-ghost"}
end
