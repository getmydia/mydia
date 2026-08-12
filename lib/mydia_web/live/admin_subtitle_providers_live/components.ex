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
      <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
        <h2 class="text-lg font-semibold flex items-center gap-2">
          <.icon name="hero-chat-bubble-bottom-center-text" class="w-5 h-5 opacity-60" />
          Subtitle Providers <span class="badge badge-ghost">{length(@providers)}</span>
        </h2>
        <button
          id="subtitle-provider-add"
          class="btn btn-sm btn-primary"
          phx-click="new_subtitle_provider"
        >
          <.icon name="hero-plus" class="w-4 h-4" /> New
        </button>
      </div>

      <%= if @providers == [] do %>
        <div class="alert alert-info">
          <.icon name="hero-information-circle" class="w-5 h-5" />
          <span>
            No subtitle providers configured yet. Built-in providers appear here on a fresh install.
          </span>
        </div>
      <% else %>
        <div class="bg-base-200 rounded-box divide-y divide-base-300">
          <%= for provider <- @providers do %>
            <% available? = Map.get(@circuit, provider.id, true) %>
            <% is_runtime = Settings.runtime_config?(provider) %>
            <% is_registry = registry_config?(provider) %>

            <div id={"subtitle-provider-row-#{provider.type}"} class="p-3 sm:p-4">
              <div class="flex flex-col sm:flex-row sm:items-center gap-3">
                <div class="flex-1 min-w-0">
                  <div class="font-semibold flex items-center gap-2 flex-wrap">
                    {provider.name}
                    <%= if is_runtime do %>
                      <span
                        class="badge badge-primary badge-xs tooltip"
                        data-tip="Configured via environment variables (read-only)"
                      >
                        <.icon name="hero-lock-closed" class="w-3 h-3" /> ENV
                      </span>
                    <% end %>
                    <%= if is_registry do %>
                      <span
                        class="badge badge-ghost badge-xs tooltip"
                        data-tip="Built-in default. Saving an edit creates a database row."
                      >
                        Default
                      </span>
                    <% end %>
                  </div>
                  <div class="text-xs opacity-60 mt-1 flex flex-wrap gap-3">
                    <span>Priority: {provider.priority}</span>
                    <span>Quota: {format_quota(provider.quota_remaining)}</span>
                    <span>
                      Circuit: {if available?, do: "available", else: "open"}
                    </span>
                  </div>
                </div>

                <div class="flex flex-wrap items-center gap-2">
                  <span class="badge badge-sm badge-outline">{format_type(provider.type)}</span>
                  <span class={[
                    "badge badge-sm",
                    if(provider.enabled, do: "badge-success", else: "badge-ghost")
                  ]}>
                    {if provider.enabled, do: "Enabled", else: "Disabled"}
                  </span>
                  <span class={[
                    "badge badge-sm",
                    if(available?, do: "badge-success", else: "badge-error")
                  ]}>
                    {if available?, do: "Healthy", else: "Circuit open"}
                  </span>

                  <div
                    class="tooltip"
                    data-tip={if provider.enabled, do: "Disable", else: "Enable"}
                  >
                    <input
                      id={"subtitle-provider-toggle-#{provider.id}"}
                      type="checkbox"
                      class="toggle toggle-success toggle-sm"
                      checked={provider.enabled}
                      phx-click="toggle_subtitle_provider"
                      phx-value-id={provider.id}
                    />
                  </div>

                  <div class="join ml-auto sm:ml-2">
                    <button
                      class="btn btn-sm btn-ghost join-item"
                      phx-click="test_subtitle_provider"
                      phx-value-id={provider.id}
                      title="Test configuration"
                    >
                      <.icon name="hero-signal" class="w-4 h-4" />
                    </button>
                    <button
                      class="btn btn-sm btn-ghost join-item"
                      phx-click="edit_subtitle_provider"
                      phx-value-id={provider.id}
                      title="Edit"
                      disabled={is_runtime}
                    >
                      <.icon name="hero-pencil" class="w-4 h-4" />
                    </button>
                    <%= if is_registry or is_runtime do %>
                      <div class="tooltip" data-tip="Cannot delete built-in or runtime providers">
                        <button class="btn btn-sm btn-ghost join-item" disabled>
                          <.icon name="hero-trash" class="w-4 h-4 opacity-30" />
                        </button>
                      </div>
                    <% else %>
                      <button
                        class="btn btn-sm btn-ghost join-item text-error"
                        phx-click="delete_subtitle_provider"
                        phx-value-id={provider.id}
                        data-confirm="Are you sure you want to delete this subtitle provider?"
                        title="Delete"
                      >
                        <.icon name="hero-trash" class="w-4 h-4" />
                      </button>
                    <% end %>
                  </div>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :mode, :atom, required: true

  def provider_modal(assigns) do
    provider_type = Phoenix.HTML.Form.input_value(assigns.form, :type)
    assigns = assign(assigns, :provider_type, provider_type)

    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <.form
          for={@form}
          id="subtitle-provider-form"
          phx-change="validate_subtitle_provider"
          phx-submit="save_subtitle_provider"
        >
          <div class="flex items-center justify-between mb-5">
            <div class="flex items-center gap-3">
              <div class="w-10 h-10 rounded-xl bg-primary/20 flex items-center justify-center">
                <.icon
                  name={if(@mode == :new, do: "hero-plus-circle", else: "hero-pencil-square")}
                  class="w-5 h-5 text-primary"
                />
              </div>
              <div>
                <h3 class="font-bold text-lg">
                  {if @mode == :new, do: "Add Subtitle Provider", else: "Edit Subtitle Provider"}
                </h3>
                <p class="text-sm text-base-content/60">
                  {if @mode == :new,
                    do: "Configure a subtitle search provider",
                    else: "Update provider settings"}
                </p>
              </div>
            </div>
            <label class="label cursor-pointer gap-2">
              <span class="label-text text-sm">Enabled</span>
              <input type="hidden" name={@form[:enabled].name} value="false" />
              <input
                type="checkbox"
                name={@form[:enabled].name}
                value="true"
                checked={Phoenix.HTML.Form.normalize_value("checkbox", @form[:enabled].value)}
                class="toggle toggle-success toggle-sm"
              />
            </label>
          </div>

          <div class="space-y-5">
            <div class="grid grid-cols-6 gap-3">
              <div class="col-span-6 md:col-span-3">
                <.input field={@form[:name]} type="text" label="Name" required />
              </div>
              <div class="col-span-3 md:col-span-2">
                <.input
                  field={@form[:type]}
                  type="select"
                  label="Type"
                  options={type_options()}
                  required
                />
              </div>
              <div class="col-span-3 md:col-span-1">
                <.input field={@form[:priority]} type="number" label="Priority" />
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
                field={@form[:api_key]}
                type="password"
                label="API Key"
                placeholder="API key"
              />
              <.input field={@form[:username]} type="text" label="Username" />
              <.input field={@form[:password]} type="password" label="Password" />
            </div>
          </div>

          <div class="modal-action mt-6 pt-4 border-t border-base-300">
            <button type="button" class="btn btn-ghost" phx-click="close_subtitle_provider_modal">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary gap-2">
              <.icon name="hero-check" class="w-4 h-4" /> Save Provider
            </button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop bg-black/50" phx-click="close_subtitle_provider_modal"></div>
    </div>
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

  defp registry_config?(%{id: id}) when is_binary(id), do: String.starts_with?(id, "registry::")
  defp registry_config?(_), do: false
end
