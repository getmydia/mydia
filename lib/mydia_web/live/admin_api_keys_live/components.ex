defmodule MydiaWeb.AdminApiKeysLive.Components do
  @moduledoc "Components for the API keys admin page."
  use MydiaWeb, :html

  alias Mydia.Accounts.ApiKey

  attr :api_keys, :list, required: true
  attr :env_key_set, :boolean, required: true

  def api_keys_tab(assigns) do
    ~H"""
    <div class="p-4 sm:p-6 space-y-4">
      <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
        <h2 class="text-lg font-semibold flex items-center gap-2">
          <.icon name="hero-key" class="w-5 h-5 opacity-60" /> API Keys
          <span class="badge badge-ghost">{length(@api_keys)}</span>
        </h2>
        <button id="new-api-key" class="btn btn-sm btn-primary" phx-click="new_api_key">
          <.icon name="hero-plus" class="w-4 h-4" /> New
        </button>
      </div>

      <p class="text-sm text-base-content/70">
        Keys for the Library API at <code>/api/library/graphql</code>, sent as the
        <code>x-api-key</code>
        header. Each key acts as you.
      </p>

      <div
        :if={@env_key_set}
        id="env-library-api-key"
        class="bg-base-200 rounded-box p-4 flex items-center gap-3"
      >
        <.icon name="hero-lock-closed" class="w-5 h-5 opacity-60" />
        <div class="flex-1">
          <div class="font-medium flex items-center gap-2">
            LIBRARY_API_KEY <MydiaWeb.AdminComponents.config_source_badge source={:env} />
          </div>
          <p class="text-sm text-base-content/70">
            Set by LIBRARY_API_KEY. Remove the variable and restart to revoke.
          </p>
        </div>
      </div>

      <%= if @api_keys == [] do %>
        <div id="api-keys-empty" class="alert alert-info">
          <.icon name="hero-information-circle" class="w-5 h-5" />
          <span>No API keys yet. Create one to use the Library API.</span>
        </div>
      <% else %>
        <div id="api-keys" class="bg-base-200 rounded-box divide-y divide-base-300">
          <.api_key_row :for={key <- @api_keys} key={key} />
        </div>
      <% end %>
    </div>
    """
  end

  attr :key, ApiKey, required: true

  defp api_key_row(assigns) do
    assigns = assign(assigns, :state, state(assigns.key))

    ~H"""
    <div id={"api-key-#{@key.id}"} class="p-4 flex flex-col sm:flex-row sm:items-center gap-3">
      <div class="flex-1 min-w-0">
        <div class="font-medium flex items-center gap-2 flex-wrap">
          {@key.name}
          <span class="badge badge-sm badge-ghost">{scope(@key)}</span>
          <span class={["badge badge-sm", state_class(@state)]}>{state_label(@state)}</span>
        </div>
        <div class="text-sm text-base-content/60 font-mono">{@key.key_prefix}...</div>
        <div class="text-xs text-base-content/60 mt-1">
          Created {date(@key.inserted_at)} · Last used {date(@key.last_used_at) || "never"} · Expires {date(
            @key.expires_at
          ) || "never"}
        </div>
      </div>
      <div class="join">
        <button
          :if={@state == :active}
          id={"revoke-api-key-#{@key.id}"}
          class="btn btn-sm btn-ghost join-item"
          phx-click="confirm_revoke_api_key"
          phx-value-id={@key.id}
          title="Revoke"
        >
          <.icon name="hero-no-symbol" class="w-4 h-4" />
        </button>
        <button
          id={"delete-api-key-#{@key.id}"}
          class="btn btn-sm btn-ghost join-item text-error"
          phx-click="confirm_delete_api_key"
          phx-value-id={@key.id}
          title="Delete"
        >
          <.icon name="hero-trash" class="w-4 h-4" />
        </button>
      </div>
    </div>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true

  def api_key_modal(assigns) do
    ~H"""
    <div id="api-key-modal" class="modal modal-open">
      <div class="modal-box max-w-lg">
        <.form for={@form} id="api-key-form" phx-change="validate_api_key" phx-submit="save_api_key">
          <h3 class="font-bold text-lg mb-4">New API key</h3>
          <.input field={@form[:name]} type="text" label="Name" placeholder="Home automation" />
          <.input
            field={@form[:expiry]}
            type="select"
            label="Expires"
            options={[
              {"Never", "never"},
              {"In 30 days", "30"},
              {"In 90 days", "90"},
              {"In 365 days", "365"}
            ]}
          />
          <.input
            field={@form[:scope]}
            type="select"
            label="Scope"
            options={[{"Library API", "library"}]}
          />
          <div class="modal-action mt-6 pt-4 border-t border-base-300">
            <button type="button" class="btn btn-ghost" phx-click="close_api_key_modal">
              Cancel
            </button>
            <button type="submit" id="save-api-key" class="btn btn-primary">Create key</button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop bg-black/50" phx-click="close_api_key_modal"></div>
    </div>
    """
  end

  attr :key, :string, required: true

  def created_key_modal(assigns) do
    ~H"""
    <div id="created-api-key-modal" class="modal modal-open">
      <div class="modal-box max-w-lg">
        <h3 class="font-bold text-lg">Your new API key</h3>
        <p class="py-2 text-sm text-base-content/70">
          Copy it now. It is shown only once and cannot be recovered.
        </p>
        <div class="join w-full">
          <input
            id="created-api-key"
            type="text"
            readonly
            value={@key}
            class="input join-item w-full font-mono"
          />
          <%!-- The key rides in an escaped data attribute, never inside the
               onclick string, so no character in it can break out into script.
               Same pattern as the devices page's claim code. --%>
          <button
            id="copy-api-key"
            class="btn join-item"
            phx-click="copy_api_key"
            data-key={@key}
            onclick="navigator.clipboard?.writeText(this.dataset.key)"
            title="Copy key"
          >
            <.icon name="hero-clipboard-document" class="w-4 h-4" />
          </button>
        </div>
        <div class="alert alert-warning mt-4">
          <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
          <span>
            This key also authenticates on the player API as you. Treat it like your password.
          </span>
        </div>
        <div class="modal-action">
          <button id="close-created-api-key" class="btn btn-primary" phx-click="close_created_api_key">
            Done
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :confirm, :any, required: true, doc: "{:revoke | :delete, %ApiKey{}}"

  def confirm_modal(%{confirm: {action, key}} = assigns) do
    assigns = assign(assigns, action: action, key: key)

    ~H"""
    <div id="api-key-confirm-modal" class="modal modal-open">
      <div class="modal-box">
        <h3 class="text-lg font-bold">
          {if @action == :revoke, do: "Revoke", else: "Delete"} '{@key.name}'?
        </h3>
        <p class="py-2">
          <%= if @action == :revoke do %>
            Anything using this key stops working immediately. It stays listed as revoked.
          <% else %>
            Anything using this key stops working immediately, and it leaves this list.
          <% end %>
        </p>
        <div class="modal-action">
          <button id="cancel-api-key-confirm" class="btn btn-ghost" phx-click="cancel_api_key_confirm">
            Cancel
          </button>
          <button
            id="confirm-api-key-action"
            class="btn btn-error"
            phx-click={"#{@action}_api_key"}
            phx-disable-with="Working..."
          >
            {if @action == :revoke, do: "Revoke key", else: "Delete key"}
          </button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="cancel_api_key_confirm"></div>
    </div>
    """
  end

  @doc false
  # Mirrors Mydia.Accounts' private not_expired?/1: a key expires at its
  # expires_at instant.
  def state(%ApiKey{revoked_at: %DateTime{}}), do: :revoked

  def state(%ApiKey{expires_at: %DateTime{} = expires_at}) do
    if DateTime.compare(DateTime.utc_now(), expires_at) == :lt, do: :active, else: :expired
  end

  def state(%ApiKey{}), do: :active

  defp state_label(:active), do: "Active"
  defp state_label(:revoked), do: "Revoked"
  defp state_label(:expired), do: "Expired"

  defp state_class(:active), do: "badge-success"
  defp state_class(_state), do: "badge-ghost"

  # Keys minted elsewhere (the player API's createApiKey) default to read/write,
  # which the Library API refuses.
  defp scope(%ApiKey{permissions: permissions}) do
    if "admin" in (permissions || []), do: "Library API", else: "Player API"
  end

  defp date(nil), do: nil
  defp date(%DateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d")
end
