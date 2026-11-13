defmodule MydiaWeb.AdminDownloadClientsLive.BuiltInFormComponents do
  @moduledoc """
  The built-in torrent client's settings modal: a Torrent and a VPN section
  over one form, so switching sections keeps what was typed in the other.

  The field rows, with their source badges and secret handling, are in
  `MydiaWeb.AdminDownloadClientsLive.BuiltInFieldComponents`.
  """
  use MydiaWeb, :html

  import MydiaWeb.AdminDownloadClientsLive.BuiltInFieldComponents

  alias Mydia.Downloads.BuiltIn.Preflight
  alias Mydia.Downloads.BuiltIn.VpnProviders
  alias MydiaWeb.AdminDownloadClientsLive.BuiltInComponents

  @form_id "built-in-settings-form"

  attr :form, Phoenix.HTML.Form, required: true
  attr :section, :atom, required: true, values: [:torrent, :vpn]
  attr :sources, :map, required: true, doc: "Settings.sources/1; a missing field reads :default"
  attr :saved_secrets, :map, required: true, doc: "%{field => Settings.secret_saved?/1}"
  attr :replacing, :list, required: true, doc: "saved secret fields the user chose to replace"
  attr :typed_secrets, :list, required: true, doc: "secret fields with a typed value"
  attr :confirm, :any, required: true, doc: "nil, {:disable, count} or :vpn_off"
  attr :preflight, :any, required: true, doc: "Preflight.read/1"
  attr :env_vpn_names, :list, required: true

  def built_in_settings_modal(assigns) do
    ~H"""
    <.admin_modal
      id="built-in-settings-modal"
      icon="hero-arrow-down-tray"
      title={gettext("Built-in torrent client")}
      subtitle={gettext("Torrent engine and VPN settings")}
      on_close="close_built_in_settings"
    >
      <.form
        for={@form}
        id={form_id()}
        phx-change="validate_built_in"
        phx-submit="save_built_in"
        class="space-y-5"
      >
        <div
          id="built-in-sections"
          role="tablist"
          aria-label={gettext("Settings section")}
          class="tabs tabs-border w-full [&>.tab]:flex-1"
        >
          <.section_tab
            section={:torrent}
            current={@section}
            label={gettext("Torrent")}
            icon="hero-arrow-down-tray"
          />
          <.section_tab
            section={:vpn}
            current={@section}
            label={gettext("VPN")}
            icon="hero-shield-check"
          />
        </div>

        <div :for={msg <- base_errors(@form)} role="alert" class="alert alert-error alert-soft">
          <.icon name="hero-exclamation-circle" class="size-5 shrink-0" />
          <span class="text-sm">{msg}</span>
        </div>

        <.torrent_section form={@form} sources={@sources} hidden?={@section != :torrent} />
        <.vpn_section
          form={@form}
          sources={@sources}
          hidden?={@section != :vpn}
          saved_secrets={@saved_secrets}
          replacing={@replacing}
          typed_secrets={@typed_secrets}
          preflight={@preflight}
          env_vpn_names={@env_vpn_names}
        />

        <.confirmation confirm={@confirm} />

        <.admin_modal_actions>
          <button
            id="built-in-settings-cancel"
            type="button"
            class="btn"
            phx-click="close_built_in_settings"
          >
            {gettext("Cancel")}
          </button>
          <button
            id="built-in-settings-save"
            type="submit"
            class={["btn", if(@confirm, do: "btn-warning", else: "btn-primary")]}
            phx-disable-with={gettext("Saving...")}
          >
            {save_label(@confirm)}
          </button>
        </.admin_modal_actions>
      </.form>
    </.admin_modal>
    """
  end

  ## Sections

  attr :section, :atom, required: true
  attr :current, :atom, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true

  defp section_tab(assigns) do
    assigns = assign(assigns, :active?, assigns.section == assigns.current)

    ~H"""
    <button
      id={"built-in-tab-#{@section}"}
      type="button"
      role="tab"
      aria-selected={to_string(@active?)}
      aria-controls={"built-in-section-#{@section}"}
      class={["tab gap-1.5", @active? && "tab-active"]}
      phx-click="built_in_section"
      phx-value-section={@section}
    >
      <.icon name={@icon} class="size-4" /> {@label}
    </button>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :sources, :map, required: true
  attr :hidden?, :boolean, required: true

  defp torrent_section(assigns) do
    ~H"""
    <section
      id="built-in-section-torrent"
      role="tabpanel"
      aria-labelledby="built-in-tab-torrent"
      class={["space-y-4", @hidden? && "hidden"]}
    >
      <.field_row field={:enabled} label={gettext("Run the built-in client")} sources={@sources}>
        <.choice
          form={@form}
          field={:enabled}
          locked?={locked?(@sources, :enabled)}
          label={gettext("Run the built-in client")}
          options={[
            {"automatic", gettext("Automatic")},
            {"true", gettext("On")},
            {"false", gettext("Off")}
          ]}
        />
        <:hint>
          {gettext("Automatic runs it when no other torrent client is configured.")}
        </:hint>
      </.field_row>

      <.text_field
        form={@form}
        field={:download_path}
        sources={@sources}
        label={gettext("Download path")}
      >
        <:hint>
          {gettext(
            "A new path applies to new grabs. Torrents already in the session finish in their original folder."
          )}
        </:hint>
      </.text_field>
      <.text_field
        form={@form}
        field={:listen_port}
        sources={@sources}
        type="number"
        label={gettext("Listen port")}
      />

      <details class="collapse collapse-arrow bg-base-200 border border-base-300">
        <summary class="collapse-title text-sm font-medium">{gettext("Advanced")}</summary>
        <div class="collapse-content space-y-4">
          <.text_field
            form={@form}
            field={:state_path}
            sources={@sources}
            label={gettext("State path")}
          >
            <:hint>
              {gettext(
                "Changing this starts a new, empty torrent session. Torrents in the old session stop being tracked by the engine."
              )}
            </:hint>
          </.text_field>
          <.text_field
            form={@form}
            field={:api_port}
            sources={@sources}
            type="number"
            label={gettext("API port")}
          />
        </div>
      </details>
    </section>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :sources, :map, required: true
  attr :hidden?, :boolean, required: true
  attr :saved_secrets, :map, required: true
  attr :replacing, :list, required: true
  attr :typed_secrets, :list, required: true
  attr :preflight, :any, required: true
  attr :env_vpn_names, :list, required: true

  defp vpn_section(assigns) do
    provider = VpnProviders.get(assigns.form[:vpn_provider].value)
    preflight = preflight_map(assigns.preflight)

    assigns =
      assigns
      |> assign(:provider, provider)
      |> assign(:vpn_type, effective_type(provider, assigns.form[:vpn_type].value))
      |> assign(:preflight_map, preflight)
      |> assign(:blocked?, preflight != nil and Preflight.blocking_reason(preflight) != nil)
      # Missing capabilities only stop the VPN being turned on; it can always be turned off.
      |> assign(
        :vpn_on?,
        Phoenix.HTML.Form.normalize_value("checkbox", assigns.form[:vpn_enabled].value)
      )

    ~H"""
    <section
      id="built-in-section-vpn"
      role="tabpanel"
      aria-labelledby="built-in-tab-vpn"
      class={["space-y-4", @hidden? && "hidden"]}
    >
      <BuiltInComponents.vpn_setup_card
        :if={@preflight_map && Enum.any?(@preflight_map, fn {_k, v} -> v == :missing end)}
        preflight={@preflight_map}
      />

      <.field_row
        field={:vpn_enabled}
        label={gettext("Route torrents through a VPN")}
        sources={@sources}
      >
        <.input
          field={@form[:vpn_enabled]}
          id="built-in-field-vpn_enabled"
          type="checkbox"
          container_class=""
          class="toggle toggle-primary"
          label={gettext("Use the VPN")}
          disabled={locked?(@sources, :vpn_enabled) or (@blocked? and not @vpn_on?)}
        />
      </.field_row>

      <.field_row field={:vpn_provider} label={gettext("Provider")} sources={@sources}>
        <.input
          field={@form[:vpn_provider]}
          id="built-in-field-vpn_provider"
          type="select"
          container_class=""
          prompt={gettext("Choose a provider")}
          options={Enum.map(VpnProviders.all(), &{&1.label, &1.name})}
          value={if(@provider, do: @provider.name, else: @form[:vpn_provider].value)}
          disabled={locked?(@sources, :vpn_provider)}
        />
      </.field_row>

      <%= if @provider do %>
        <.field_row
          :if={length(@provider.types) > 1}
          field={:vpn_type}
          label={gettext("VPN type")}
          sources={@sources}
        >
          <%= if locked?(@sources, :vpn_type) do %>
            <p class="text-sm">{type_label(@vpn_type)}</p>
          <% else %>
            <.segmented_control
              id="built-in-vpn-type"
              value={@vpn_type}
              event="validate_built_in"
              param="vpn_type"
              label={gettext("VPN type")}
            >
              <:option
                :for={type <- @provider.types}
                id={"built-in-vpn-type-#{type}"}
                value={type}
                label={type_label(type)}
              />
            </.segmented_control>
          <% end %>
        </.field_row>
        <input
          :if={!locked?(@sources, :vpn_type)}
          type="hidden"
          name={@form[:vpn_type].name}
          value={@vpn_type}
        />

        <.credential_fields
          form={@form}
          sources={@sources}
          vpn_type={@vpn_type}
          saved_secrets={@saved_secrets}
          replacing={@replacing}
          typed_secrets={@typed_secrets}
        />

        <.extra_env_note provider={@provider} vpn_type={@vpn_type} />
      <% else %>
        <p class="text-sm text-base-content/60">
          {gettext("Choose a provider to see its sign-in fields.")}
        </p>
      <% end %>

      <fieldset
        id="built-in-server-location"
        class="fieldset bg-base-200 border border-base-300 rounded-box p-4"
      >
        <legend class="fieldset-legend">{gettext("Server location")}</legend>
        <div class="grid grid-cols-1 sm:grid-cols-2 gap-x-4">
          <.text_field
            form={@form}
            field={:vpn_server_countries}
            sources={@sources}
            label={gettext("Server countries")}
          />
          <.text_field
            form={@form}
            field={:vpn_server_regions}
            sources={@sources}
            label={gettext("Server regions")}
          />
          <.text_field
            form={@form}
            field={:vpn_server_cities}
            sources={@sources}
            label={gettext("Server cities")}
          />
          <.text_field
            form={@form}
            field={:vpn_server_hostnames}
            sources={@sources}
            label={gettext("Server hostnames")}
          />
        </div>
        <p class="label">
          {gettext("Comma-separated. Leave blank to let the provider choose.")}
        </p>
      </fieldset>

      <.field_row
        :if={@provider && @provider.port_forwarding?}
        field={:vpn_port_forwarding}
        label={gettext("Port forwarding")}
        sources={@sources}
      >
        <.input
          field={@form[:vpn_port_forwarding]}
          id="built-in-field-vpn_port_forwarding"
          type="checkbox"
          container_class=""
          class="toggle toggle-primary"
          label={gettext("Ask the provider for a forwarded port")}
          disabled={locked?(@sources, :vpn_port_forwarding)}
        />
      </.field_row>
      <%!-- Without the toggle, a value saved for the previous provider would
           block Save with an error on a field the form no longer shows. --%>
      <input
        :if={!(@provider && @provider.port_forwarding?) and !locked?(@sources, :vpn_port_forwarding)}
        type="hidden"
        name={@form[:vpn_port_forwarding].name}
        value="false"
      />

      <fieldset
        :if={@env_vpn_names != []}
        class="fieldset bg-base-200 border border-base-300 rounded-box p-4"
      >
        <legend class="fieldset-legend">{gettext("Also set from environment")}</legend>
        <ul id="built-in-env-vpn-names" class="flex flex-wrap gap-2">
          <li :for={name <- @env_vpn_names}>
            <code class="badge badge-sm badge-outline font-mono">{name}</code>
          </li>
        </ul>
      </fieldset>
    </section>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :sources, :map, required: true
  attr :vpn_type, :string, required: true
  attr :saved_secrets, :map, required: true
  attr :replacing, :list, required: true
  attr :typed_secrets, :list, required: true

  defp credential_fields(assigns) do
    ~H"""
    <%= if @vpn_type == "wireguard" do %>
      <.secret_field
        form={@form}
        field={:vpn_wireguard_private_key}
        label={gettext("WireGuard private key")}
        sources={@sources}
        saved_secrets={@saved_secrets}
        replacing={@replacing}
        typed_secrets={@typed_secrets}
      />
      <.text_field
        form={@form}
        field={:vpn_wireguard_addresses}
        sources={@sources}
        label={gettext("WireGuard addresses")}
        placeholder="10.64.0.2/32"
      />
    <% else %>
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <.text_field
          form={@form}
          field={:vpn_openvpn_user}
          sources={@sources}
          label={gettext("OpenVPN username")}
          autocomplete="off"
        />
        <.secret_field
          form={@form}
          field={:vpn_openvpn_password}
          label={gettext("OpenVPN password")}
          sources={@sources}
          saved_secrets={@saved_secrets}
          replacing={@replacing}
          typed_secrets={@typed_secrets}
        />
      </div>
    <% end %>
    """
  end

  attr :provider, :map, required: true
  attr :vpn_type, :string, required: true

  defp extra_env_note(assigns) do
    assigns =
      assign(assigns, :names, VpnProviders.extra_env(assigns.provider.name, assigns.vpn_type))

    ~H"""
    <div
      :if={@names != []}
      id="built-in-vpn-extra-env"
      role="note"
      class="alert alert-info alert-soft text-sm items-start"
    >
      <.icon name="hero-information-circle" class="size-5 shrink-0" />
      <div class="min-w-0 space-y-1">
        <p>
          {gettext(
            "%{provider} also needs these variables, which must be set in the container environment:",
            provider: @provider.label
          )}
        </p>
        <ul class="flex flex-wrap gap-2">
          <li :for={name <- @names}>
            <code class="font-mono text-xs break-all">MYDIA_VPN_{name}</code>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  attr :confirm, :any, required: true

  defp confirmation(%{confirm: {:disable, count}} = assigns) do
    assigns = assign(assigns, :count, count)

    ~H"""
    <div id="built-in-confirm-disable" role="alert" class="alert alert-warning items-start">
      <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
      <p class="text-sm">
        {ngettext(
          "Turning the built-in client off stops %{count} download that is still in progress. Save again to turn it off.",
          "Turning the built-in client off stops %{count} downloads that are still in progress. Save again to turn it off.",
          @count
        )}
      </p>
    </div>
    """
  end

  defp confirmation(%{confirm: :vpn_off} = assigns) do
    ~H"""
    <div id="built-in-confirm-vpn-off" role="alert" class="alert alert-warning items-start">
      <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
      <p class="text-sm">
        {gettext(
          "Torrents will connect without the VPN, from this server's own address. Save again to turn the VPN off."
        )}
      </p>
    </div>
    """
  end

  defp confirmation(assigns), do: ~H""

  ## Helpers

  defp form_id, do: @form_id

  defp preflight_map({:ok, map}), do: map
  defp preflight_map(_), do: nil

  # The type the form will submit: the chosen one when the provider offers it,
  # otherwise the provider's first.
  defp effective_type(nil, type), do: type

  defp effective_type(provider, type) when is_binary(type) and type != "" do
    if type in provider.types, do: type, else: hd(provider.types)
  end

  defp effective_type(provider, _type), do: hd(provider.types)

  defp type_label("wireguard"), do: "WireGuard"
  defp type_label("openvpn"), do: "OpenVPN"
  defp type_label(other), do: other

  defp base_errors(form) do
    for {:base, error} <- form.errors, do: translate_error(error)
  end

  defp save_label({:disable, _}), do: gettext("Turn off and save")
  defp save_label(:vpn_off), do: gettext("Turn VPN off and save")
  defp save_label(_), do: gettext("Save")
end
