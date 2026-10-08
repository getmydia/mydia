defmodule MydiaWeb.AdminSubtitleProvidersLive.Components do
  @moduledoc false
  use MydiaWeb, :html

  alias Mydia.Settings
  alias Mydia.Subtitles.ProviderRegistry

  attr :providers, :list, required: true
  attr :circuit, :map, required: true

  def providers_tab(assigns) do
    ~H"""
    <div class="p-4 sm:p-6 space-y-4">
      <.admin_list id="subtitle-providers" items={@providers}>
        <:row :let={provider}>
          <.subtitle_provider_row
            provider={provider}
            available?={Map.get(@circuit, provider.id, true)}
          />
        </:row>
        <:empty>
          No subtitle providers configured yet. Built-in providers appear here on a fresh install.
        </:empty>
      </.admin_list>
    </div>
    """
  end

  attr :provider, :map, required: true
  attr :available?, :boolean, required: true

  defp subtitle_provider_row(assigns) do
    assigns =
      assigns
      |> assign(:runtime?, Settings.runtime_config?(assigns.provider))
      |> assign(:registry?, registry_config?(assigns.provider))

    ~H"""
    <.admin_row id={"subtitle-provider-row-#{@provider.type}"}>
      <:title>
        {@provider.name}
        <.env_lock_badge :if={@runtime?} />
        <span
          :if={@registry?}
          class="badge badge-ghost badge-xs tooltip"
          data-tip="Built-in default. Saving an edit creates a database row."
        >
          Default
        </span>
      </:title>
      <:descriptor>
        Priority: {@provider.priority} · Quota: {format_quota(@provider.quota_remaining)} · Circuit: {if @available?,
          do: "available",
          else: "open"}
      </:descriptor>
      <:badges>
        <span class="badge badge-sm badge-outline">{format_type(@provider.type)}</span>
        <span class={[
          "badge badge-sm",
          if(@provider.enabled, do: "badge-success", else: "badge-ghost")
        ]}>
          {if @provider.enabled, do: "Enabled", else: "Disabled"}
        </span>
        <span class={["badge badge-sm", if(@available?, do: "badge-success", else: "badge-error")]}>
          {if @available?, do: "Healthy", else: "Circuit open"}
        </span>
        <input
          id={"subtitle-provider-toggle-#{@provider.id}"}
          type="checkbox"
          class="toggle toggle-success toggle-sm"
          aria-label={
            if @provider.enabled, do: "Disable #{@provider.name}", else: "Enable #{@provider.name}"
          }
          checked={@provider.enabled}
          disabled={@runtime?}
          phx-click="toggle_subtitle_provider"
          phx-value-id={@provider.id}
        />
      </:badges>
      <:actions>
        <.row_actions>
          <.row_action
            icon="hero-signal"
            title="Test configuration"
            phx-click="test_subtitle_provider"
            phx-value-id={@provider.id}
          />
          <.row_action
            icon="hero-pencil"
            title="Edit"
            disabled={@runtime?}
            disabled_reason={@runtime? && env_read_only_reason()}
            phx-click="edit_subtitle_provider"
            phx-value-id={@provider.id}
          />
          <.row_action
            icon="hero-trash"
            title="Delete"
            destructive
            disabled={@registry? or @runtime?}
            disabled_reason={
              (@registry? or @runtime?) && "Built-in and environment providers cannot be deleted"
            }
            phx-click="delete_subtitle_provider"
            phx-value-id={@provider.id}
            data-confirm="Are you sure you want to delete this subtitle provider?"
          />
        </.row_actions>
      </:actions>
    </.admin_row>
    """
  end

  @doc "The page header's New button."
  def header_actions(assigns) do
    ~H"""
    <button
      id="subtitle-provider-add"
      class="btn btn-sm btn-primary"
      phx-click="new_subtitle_provider"
    >
      <.icon name="hero-plus" class="w-4 h-4" /> New
    </button>
    """
  end

  attr :subtitle_provider_form, :any, required: true
  attr :subtitle_provider_mode, :atom, required: true

  def provider_modal(assigns) do
    provider_type = Phoenix.HTML.Form.input_value(assigns.subtitle_provider_form, :type)
    assigns = assign(assigns, :provider_type, provider_type)

    ~H"""
    <.admin_modal
      id="subtitle-provider-modal"
      icon={if @subtitle_provider_mode == :new, do: "hero-plus-circle", else: "hero-pencil-square"}
      title={
        if @subtitle_provider_mode == :new,
          do: "Add Subtitle Provider",
          else: "Edit Subtitle Provider"
      }
      subtitle={
        if @subtitle_provider_mode == :new,
          do: "Configure a subtitle search provider",
          else: "Update provider settings"
      }
      on_close="close_subtitle_provider_modal"
    >
      <:header_aside>
        <label class="label cursor-pointer gap-2">
          <span class="label-text text-sm">Enabled</span>
          <input
            type="hidden"
            name={@subtitle_provider_form[:enabled].name}
            value="false"
            form="subtitle-provider-form"
          />
          <input
            type="checkbox"
            name={@subtitle_provider_form[:enabled].name}
            value="true"
            checked={
              Phoenix.HTML.Form.normalize_value("checkbox", @subtitle_provider_form[:enabled].value)
            }
            class="toggle toggle-success toggle-sm"
            form="subtitle-provider-form"
          />
        </label>
      </:header_aside>
      <.form
        for={@subtitle_provider_form}
        id="subtitle-provider-form"
        phx-change="validate_subtitle_provider"
        phx-submit="save_subtitle_provider"
      >
        <div class="space-y-5">
          <div class="grid grid-cols-6 gap-3">
            <div class="col-span-6 md:col-span-3">
              <.input field={@subtitle_provider_form[:name]} type="text" label="Name" required />
            </div>
            <div class="col-span-3 md:col-span-2">
              <.input
                field={@subtitle_provider_form[:type]}
                type="select"
                label="Type"
                options={type_options()}
                required
              />
            </div>
            <div class="col-span-3 md:col-span-1">
              <.input field={@subtitle_provider_form[:priority]} type="number" label="Priority" />
            </div>
          </div>

          <div class="divider my-1"></div>

          <div class="space-y-3">
            <div class="flex items-center gap-2 text-sm font-medium text-base-content/80">
              <.icon name="hero-key" class="w-4 h-4" />
              <span>Credentials</span>
            </div>
            <p class="text-sm text-base-content/60">
              {credentials_hint(@provider_type)}
            </p>
            <%!-- Always render credential inputs so form tests can fill them
                 before a type change re-renders the modal. --%>
            <.input
              field={@subtitle_provider_form[:api_key]}
              type="password"
              label="API Key"
              placeholder="API key"
            />
            <.input field={@subtitle_provider_form[:username]} type="text" label="Username" />
            <.input field={@subtitle_provider_form[:password]} type="password" label="Password" />
          </div>
        </div>

        <.admin_modal_actions>
          <button type="button" class="btn btn-ghost" phx-click="close_subtitle_provider_modal">
            Cancel
          </button>
          <button type="submit" class="btn btn-primary gap-2">
            <.icon name="hero-check" class="w-4 h-4" /> Save Provider
          </button>
        </.admin_modal_actions>
      </.form>
    </.admin_modal>
    """
  end

  defp type_options do
    ProviderRegistry.builtins()
    |> Enum.map(fn builtin -> {builtin.name, to_string(builtin.type)} end)
  end

  defp credentials_hint(type) when type in ["subdl", :subdl],
    do: "SubDL requires an API key."

  defp credentials_hint(type) when type in ["opensubtitles", :opensubtitles],
    do: "OpenSubtitles requires an API key, a username and a password."

  defp credentials_hint(_),
    do: "This provider needs no credentials. Leave these fields blank."

  defp format_type(type) when is_atom(type), do: type |> to_string() |> String.capitalize()
  defp format_type(type), do: to_string(type)

  defp format_quota(nil), do: "unknown"
  defp format_quota(remaining), do: to_string(remaining)

  @doc "True for a built-in provider that has no database row yet."
  def registry_config?(%{id: id}) when is_binary(id), do: String.starts_with?(id, "registry::")
  def registry_config?(_), do: false
end
