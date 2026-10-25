defmodule MydiaWeb.AdminApiKeysLive.Components do
  @moduledoc "Components for the API keys admin page."
  use MydiaWeb, :html

  alias Mydia.Accounts.ApiKey

  attr :display, Mydia.TimeDisplay, required: true
  attr :api_keys, :list, required: true
  attr :env_key_set, :boolean, required: true

  def api_keys_tab(assigns) do
    ~H"""
    <p class="text-sm text-base-content/70">
      {gettext("Keys for the Library API at")} <code>/api/library/graphql</code>{gettext(
        ", sent as the"
      )}
      <code>x-api-key</code>
      {gettext("header. Each key acts as you.")}
    </p>

    <div :if={@env_key_set} class="bg-base-200 rounded-box">
      <.admin_row id="env-library-api-key">
        <:title>LIBRARY_API_KEY <.env_lock_badge /></:title>
        <:details>
          {gettext("Set by LIBRARY_API_KEY. Remove the variable and restart to revoke.")}
        </:details>
      </.admin_row>
    </div>

    <.admin_list id="api-keys" items={@api_keys}>
      <:row :let={key}><.api_key_row key={key} display={@display} /></:row>
      <:empty>{gettext("No API keys yet. Create one to use the Library API.")}</:empty>
    </.admin_list>
    """
  end

  @doc "The page header's New button."
  def header_actions(assigns) do
    ~H"""
    <button id="new-api-key" class="btn btn-sm btn-primary" phx-click="new_api_key">
      <.icon name="hero-plus" class="w-4 h-4" /> {pgettext("api key", "New")}
    </button>
    """
  end

  attr :display, Mydia.TimeDisplay, required: true
  attr :key, ApiKey, required: true

  defp api_key_row(assigns) do
    assigns = assign(assigns, :state, state(assigns.key))

    ~H"""
    <.admin_row id={"api-key-#{@key.id}"}>
      <:title>{@key.name}</:title>
      <:descriptor>
        <span class="font-mono">{@key.key_prefix}...</span>
        · {gettext("Created %{created} · Last used %{last_used} · Expires %{expires}",
          created: date(@key.inserted_at, @display),
          last_used: date(@key.last_used_at, @display) || gettext("never"),
          expires: date(@key.expires_at, @display) || gettext("never")
        )}
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
            title={gettext("Revoke")}
            phx-click="confirm_revoke_api_key"
            phx-value-id={@key.id}
          />
          <.row_action
            id={"delete-api-key-#{@key.id}"}
            icon="hero-trash"
            title={gettext("Delete")}
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
      title={gettext("New API key")}
      subtitle={gettext("A key for the Library API")}
      on_close="close_api_key_modal"
    >
      <.form for={@form} id="api-key-form" phx-change="validate_api_key" phx-submit="save_api_key">
        <.input
          field={@form[:name]}
          type="text"
          label={gettext("Name")}
          placeholder={gettext("Home automation")}
        />
        <.input
          field={@form[:expiry]}
          type="select"
          label={gettext("Expires")}
          options={[
            {gettext("Never"), "never"},
            {gettext("In 30 days"), "30"},
            {gettext("In 90 days"), "90"},
            {gettext("In 365 days"), "365"}
          ]}
        />
        <.input
          field={@form[:scope]}
          type="select"
          label={gettext("Scope")}
          options={[{gettext("Library API"), "library"}]}
        />
        <.admin_modal_actions>
          <button type="button" class="btn btn-ghost" phx-click="close_api_key_modal">
            {gettext("Cancel")}
          </button>
          <button type="submit" id="save-api-key" class="btn btn-primary">
            {gettext("Create key")}
          </button>
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
      title={gettext("Your new API key")}
      subtitle={gettext("Copy it now. It is shown only once and cannot be recovered.")}
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
          title={gettext("Copy key")}
        >
          <.icon name="hero-clipboard-document" class="w-4 h-4" />
        </button>
      </div>
      <div class="alert alert-warning mt-4">
        <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
        <span>
          {gettext(
            "This key also authenticates on the player API as you. Treat it like your password."
          )}
        </span>
      </div>
      <:actions>
        <button
          id="close-created-api-key"
          class="btn btn-primary"
          phx-click="close_created_api_key_modal"
        >
          {gettext("Done")}
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
      title={confirm_title(@action, @key)}
      on_close="close_api_key_confirm_modal"
    >
      <p>
        <%= if @action == :revoke do %>
          {gettext("Anything using this key stops working immediately. It stays listed as revoked.")}
        <% else %>
          {gettext("Anything using this key stops working immediately, and it leaves this list.")}
        <% end %>
      </p>
      <:actions>
        <button
          id="cancel-api-key-confirm"
          class="btn btn-ghost"
          phx-click="close_api_key_confirm_modal"
        >
          {gettext("Cancel")}
        </button>
        <button
          id="confirm-api-key-action"
          class="btn btn-error"
          phx-click={"#{@action}_api_key"}
          phx-disable-with={gettext("Working...")}
        >
          {if @action == :revoke, do: gettext("Revoke key"), else: gettext("Delete key")}
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

  defp confirm_title(:revoke, key), do: gettext("Revoke '%{name}'?", name: key.name)
  defp confirm_title(:delete, key), do: gettext("Delete '%{name}'?", name: key.name)

  defp state_label(:active), do: gettext("Active")
  defp state_label(:revoked), do: gettext("Revoked")
  defp state_label(:expired), do: gettext("Expired")

  defp state_class(:active), do: "badge-success"
  defp state_class(_state), do: "badge-ghost"

  # Keys minted elsewhere (the player API's createApiKey) default to read/write,
  # which the Library API refuses.
  defp scope(%ApiKey{permissions: permissions}) do
    if "admin" in (permissions || []), do: gettext("Library API"), else: gettext("Player API")
  end

  defp date(nil, _display), do: nil
  defp date(%DateTime{} = value, display), do: format(value, :date, display)
end
