defmodule MydiaWeb.AdminSettingsLive.ProxyComponents do
  @moduledoc """
  The Outbound proxy row and its edit modal on Admin Settings. Values and
  writes live in `MydiaWeb.AdminSettingsLive.ProxySettings`; events are
  handled by `MydiaWeb.AdminSettingsLive.Index`.
  """
  use MydiaWeb, :html

  attr :settings, MydiaWeb.AdminSettingsLive.ProxySettings, required: true
  attr :test_result, :any, default: nil, doc: "nil, :running or a test_connection/1 result"

  def proxy_section(assigns) do
    ~H"""
    <.admin_section id="proxy-settings" title={gettext("Outbound proxy")} icon="hero-globe-alt">
      <.admin_list id="proxy-list" items={[@settings]}>
        <:row :let={settings}>
          <.admin_row id="proxy-row">
            <:title>
              {gettext("HTTP proxy")}
              <span id="proxy-source">
                <.proxy_source_badge source={settings.url_source} standard_label="HTTP_PROXY env" />
              </span>
            </:title>
            <:descriptor>
              <span :if={settings.url} id="proxy-url-value" class="font-mono">{settings.url}</span>
              <span :if={!settings.url} id="proxy-url-value">
                {gettext("Not configured: requests go direct")}
              </span>
            </:descriptor>
            <:details>
              <span id="proxy-bypass-value">
                {gettext("Bypass: %{hosts}",
                  hosts:
                    settings.bypass || gettext("none (local and private addresses always go direct)")
                )}
              </span>
              <span :if={@test_result} id="proxy-test-result" class="block mt-1">
                <.test_result result={@test_result} />
              </span>
            </:details>
            <:actions>
              <.row_actions>
                <.row_action
                  id="proxy-test"
                  icon="hero-signal"
                  title={gettext("Test proxy")}
                  disabled={!settings.configured?}
                  disabled_reason={if(!settings.configured?, do: gettext("No proxy is configured"))}
                  loading={@test_result == :running}
                  phx-click="test_proxy"
                />
                <.row_action
                  id="proxy-edit"
                  icon="hero-pencil"
                  title={gettext("Edit")}
                  phx-click="edit_proxy"
                />
              </.row_actions>
            </:actions>
          </.admin_row>
        </:row>
        <:empty>{gettext("Proxy settings are unavailable.")}</:empty>
      </.admin_list>
    </.admin_section>
    """
  end

  attr :result, :any, required: true

  defp test_result(%{result: :running} = assigns) do
    ~H"""
    <span class="opacity-60">{gettext("Testing the proxy...")}</span>
    """
  end

  defp test_result(%{result: {:ok, %{status: status, ms: ms}}} = assigns) do
    assigns = assign(assigns, status: status, ms: ms)

    ~H"""
    <span class={if(@status in 200..399, do: "text-success", else: "text-warning")}>
      {gettext("The metadata relay answered HTTP %{status} through the proxy in %{ms} ms",
        status: @status,
        ms: @ms
      )}
    </span>
    """
  end

  defp test_result(%{result: {:error, message}} = assigns) do
    assigns = assign(assigns, :message, message)

    ~H"""
    <span class="text-error">{gettext("Proxy test failed: %{message}", message: @message)}</span>
    """
  end

  @doc """
  The edit modal: URL and bypass list, each with its source. A field set by a
  `MYDIA_PROXY_*` variable renders disabled, since the variable wins.
  """
  attr :form, Phoenix.HTML.Form, required: true
  attr :settings, MydiaWeb.AdminSettingsLive.ProxySettings, required: true

  def proxy_modal(assigns) do
    ~H"""
    <.admin_modal
      id="proxy-modal"
      icon="hero-globe-alt"
      title={gettext("Outbound proxy")}
      subtitle={gettext("HTTP or HTTPS proxy for outgoing requests")}
      on_close="close_proxy_modal"
    >
      <.form for={@form} id="proxy-form" phx-change="validate_proxy" phx-submit="save_proxy">
        <p class="text-sm text-base-content/70 mb-4">
          {gettext(
            "Mydia sends its outgoing HTTP requests through this proxy. Local and private addresses always go direct. Leave the URL empty to fall back to HTTPS_PROXY or HTTP_PROXY when set."
          )}
        </p>

        <.proxy_field
          field={@form[:url]}
          label={gettext("Proxy URL")}
          placeholder="http://user:password@proxy:3128"
          source={@settings.url_source}
          standard_label="HTTP_PROXY env"
          help={gettext("The password shows as ****. Leave it that way to keep the saved one.")}
        />
        <.proxy_field
          field={@form[:bypass]}
          label={gettext("Bypass")}
          placeholder="10.0.0.0/8,.lan,nas.home.example"
          source={@settings.bypass_source}
          standard_label="NO_PROXY env"
          help={gettext("Comma-separated hosts, domains, IP addresses or CIDR ranges.")}
        />

        <.admin_modal_actions>
          <button type="button" class="btn btn-ghost" phx-click="close_proxy_modal">
            {gettext("Cancel")}
          </button>
          <button id="proxy-save" type="submit" class="btn btn-primary">{gettext("Save")}</button>
        </.admin_modal_actions>
      </.form>
    </.admin_modal>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :placeholder, :string, default: nil
  attr :source, :atom, required: true
  attr :standard_label, :string, required: true
  attr :help, :string, default: nil

  defp proxy_field(assigns) do
    ~H"""
    <div>
      <div class="flex items-center gap-2">
        <span class="text-sm font-medium">{@label}</span>
        <.proxy_source_badge source={@source} standard_label={@standard_label} size="xs" />
        <span :if={@source == :env} class="text-xs text-base-content/50">
          {gettext("read-only (set via environment)")}
        </span>
      </div>
      <.input
        field={@field}
        type="text"
        placeholder={@placeholder}
        disabled={@source == :env}
        autocomplete="off"
        class="input input-bordered w-full font-mono"
      />
      <p :if={@help} class="text-xs text-base-content/60 mb-3">{@help}</p>
    </div>
    """
  end

  attr :source, :atom, required: true
  attr :standard_label, :string, required: true
  attr :size, :string, default: "sm"

  # config_source_badge has four states (ENV, DB, YAML, Default); a value
  # falling back to a standard proxy variable needs a fifth, naming it.
  defp proxy_source_badge(%{source: :standard_env} = assigns) do
    ~H"""
    <span class={[
      "badge badge-info badge-outline",
      if(@size == "xs", do: "badge-xs", else: "badge-sm")
    ]}>
      {@standard_label}
    </span>
    """
  end

  defp proxy_source_badge(assigns) do
    ~H"""
    <.config_source_badge source={@source} size={@size} />
    """
  end
end
