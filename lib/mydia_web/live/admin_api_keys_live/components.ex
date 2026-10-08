defmodule MydiaWeb.AdminApiKeysLive.Components do
  @moduledoc "Components for the API keys admin page."
  use MydiaWeb, :html

  alias Mydia.Accounts.ApiKey

  attr :api_keys, :list, required: true
  attr :env_key_set, :boolean, required: true

  def api_keys_tab(assigns) do
    ~H"""
    <div class="p-4 sm:p-6 space-y-4">
      <p class="text-sm text-base-content/70">
        Keys for the Library API at <code>/api/library/graphql</code>, sent as the
        <code>x-api-key</code>
        header. Each key acts as you.
      </p>

      <div :if={@env_key_set} class="bg-base-200 rounded-box">
        <.admin_row id="env-library-api-key">
          <:title>LIBRARY_API_KEY <.env_lock_badge /></:title>
          <:details>
            Set by LIBRARY_API_KEY. Remove the variable and restart to revoke.
          </:details>
        </.admin_row>
      </div>

      <.admin_list id="api-keys" items={@api_keys}>
        <:row :let={key}><.api_key_row key={key} /></:row>
        <:empty>No API keys yet. Create one to use the Library API.</:empty>
      </.admin_list>
    </div>
    """
  end

  @doc "The page header's New button."
  def header_actions(assigns) do
    ~H"""
    <button id="new-api-key" class="btn btn-sm btn-primary" phx-click="new_api_key">
      <.icon name="hero-plus" class="w-4 h-4" /> New
    </button>
    """
  end

  attr :key, ApiKey, required: true

  defp api_key_row(assigns) do
    assigns = assign(assigns, :state, state(assigns.key))

    ~H"""
    <.admin_row id={"api-key-#{@key.id}"}>
      <:title>{@key.name}</:title>
      <:descriptor>
        <span class="font-mono">{@key.key_prefix}...</span>
        · Created {date(@key.inserted_at)} · Last used {date(@key.last_used_at) || "never"} · Expires {date(
          @key.expires_at
        ) || "never"}
      </:descriptor>
      <:badges>
        <span class="badge badge-sm badge-outline">{scope(@key)}</span>
        <span class={["badge badge-sm", state_class(@state)]}>{state_label(@state)}</span>
      </:badges>
      <:actions>
        <.row_actions>
          <.row_action
            :if={@state == :active}
            id={"revoke-api-key-#{@key.id}"}
            icon="hero-no-symbol"
            title="Revoke"
            phx-click="confirm_revoke_api_key"
            phx-value-id={@key.id}
          />
          <.row_action
            id={"delete-api-key-#{@key.id}"}
            icon="hero-trash"
            title="Delete"
            destructive
            phx-click="confirm_delete_api_key"
            phx-value-id={@key.id}
          />
        </.row_actions>
      </:actions>
    </.admin_row>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true

  def api_key_modal(assigns) do
    ~H"""
    <.admin_modal
      id="api-key-modal"
      icon="hero-key"
      title="New API key"
      subtitle="A key for the Library API"
      on_close="close_api_key_modal"
    >
      <.form for={@form} id="api-key-form" phx-change="validate_api_key" phx-submit="save_api_key">
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
        <.admin_modal_actions>
          <button type="button" class="btn btn-ghost" phx-click="close_api_key_modal">
            Cancel
          </button>
          <button type="submit" id="save-api-key" class="btn btn-primary">Create key</button>
        </.admin_modal_actions>
      </.form>
    </.admin_modal>
    """
  end

  attr :created_api_key, :string, required: true

  def created_key_modal(assigns) do
    ~H"""
    <.admin_modal
      id="created-api-key-modal"
      icon="hero-key"
      title="Your new API key"
      subtitle="Copy it now. It is shown only once and cannot be recovered."
      on_close={nil}
    >
      <div class="join w-full">
        <input
          id="created-api-key"
          type="text"
          readonly
          value={@created_api_key}
          class="input join-item w-full font-mono"
        />
        <%!-- The key rides in an escaped data attribute, never inside the
             onclick string, so no character in it can break out into script.
             Same pattern as the devices page's claim code. --%>
        <button
          id="copy-api-key"
          class="btn join-item"
          phx-click="copy_api_key"
          data-key={@created_api_key}
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
      <:actions>
        <button
          id="close-created-api-key"
          class="btn btn-primary"
          phx-click="close_created_api_key_modal"
        >
          Done
        </button>
      </:actions>
    </.admin_modal>
    """
  end

  attr :api_key_confirm, :any, required: true, doc: "{:revoke | :delete, %ApiKey{}}"

  def confirm_modal(%{api_key_confirm: {action, key}} = assigns) do
    assigns = assign(assigns, action: action, key: key)

    ~H"""
    <.admin_modal
      id="api-key-confirm-modal"
      tone={:error}
      icon={if @action == :revoke, do: "hero-no-symbol", else: "hero-trash"}
      title={"#{if @action == :revoke, do: "Revoke", else: "Delete"} '#{@key.name}'?"}
      on_close="close_api_key_confirm_modal"
    >
      <p>
        <%= if @action == :revoke do %>
          Anything using this key stops working immediately. It stays listed as revoked.
        <% else %>
          Anything using this key stops working immediately, and it leaves this list.
        <% end %>
      </p>
      <:actions>
        <button
          id="cancel-api-key-confirm"
          class="btn btn-ghost"
          phx-click="close_api_key_confirm_modal"
        >
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
      </:actions>
    </.admin_modal>
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
