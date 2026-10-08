defmodule MydiaWeb.AdminUsersLive.Components do
  @moduledoc false
  use MydiaWeb, :html

  alias Mydia.Accounts
  alias Mydia.Accounts.User

  @doc "The page header's Create button."
  def header_actions(assigns) do
    ~H"""
    <button id="create-user-button" phx-click="open_create_modal" class="btn btn-sm btn-primary">
      <.icon name="hero-plus" class="w-4 h-4" /> Create Local User
    </button>
    """
  end

  attr :users, :list, required: true, doc: "maps of %{user, requests_*} from load_users/1"
  attr :current_user, :map, required: true
  attr :search_query, :string, default: ""
  attr :filter_role, :string, required: true

  def users_tab(assigns) do
    ~H"""
    <div class="p-4 sm:p-6 space-y-4">
      <div class="alert alert-info">
        <.icon name="hero-information-circle" class="w-6 h-6" />
        <div>
          <div class="font-semibold">OIDC Auto-Registration</div>
          <div class="text-sm">
            Users authenticating via OIDC will be automatically registered on first login.
            Use "Create Local User" to manually create users with local authentication.
          </div>
        </div>
      </div>

      <div class="flex flex-col sm:flex-row gap-2">
        <.form
          for={%{}}
          as={:search}
          id="users-search-form"
          phx-change="search_users"
          class="flex-1"
        >
          <input
            type="text"
            name="search"
            value={@search_query}
            placeholder="Search by username, email, or name..."
            aria-label="Search users"
            class="input input-bordered w-full"
          />
        </.form>
        <select
          id="users-role-filter"
          phx-change="filter_users"
          name="role"
          aria-label="Filter by role"
          class="select select-bordered"
        >
          <option value="all" selected={@filter_role == "all"}>All Roles</option>
          <option value="admin" selected={@filter_role == "admin"}>Admin</option>
          <option value="user" selected={@filter_role == "user"}>User</option>
          <option value="readonly" selected={@filter_role == "readonly"}>Read Only</option>
          <option value="guest" selected={@filter_role == "guest"}>Guest</option>
        </select>
      </div>

      <.admin_table id="users" rows={@users} row_id={&"user-#{&1.user.id}"}>
        <:col :let={data} label="User">
          <.user_cell user={data.user} />
        </:col>
        <:col :let={data} label="Auth Type">
          <.auth_cell user={data.user} />
        </:col>
        <:col :let={data} label="Role">
          <span class={"badge #{role_badge_class(data.user.role)} badge-lg"}>
            {String.capitalize(data.user.role)}
          </span>
        </:col>
        <:col :let={data} label="Last Login">
          <span class="text-sm">{format_date(data.user.last_login_at)}</span>
        </:col>
        <:col :let={data} label="Statistics">
          <.stats_cell data={data} />
        </:col>
        <:action :let={data}>
          <.row_action
            icon="hero-pencil"
            title="Edit role"
            phx-click="open_edit_role_modal"
            phx-value-id={data.user.id}
          />
          <.row_action
            :if={!oidc_user?(data.user)}
            icon="hero-key"
            title="Reset password"
            phx-click="open_reset_password_modal"
            phx-value-id={data.user.id}
          />
          <.row_action
            :if={second_factor_on?(data.user)}
            id={"reset-2fa-#{data.user.id}"}
            icon="hero-shield-exclamation"
            title="Reset two-factor authentication"
            phx-click="reset_second_factors"
            phx-value-id={data.user.id}
            data-confirm="Turn off two-factor authentication for this user? This removes their authenticator app and all their passkeys. They will sign in with only their password until they set it up again."
          />
          <.row_action
            :if={data.user.role != "admin"}
            id={"open-access-#{data.user.id}"}
            icon="hero-shield-check"
            title="Library access"
            phx-click="open_access_modal"
            phx-value-id={data.user.id}
          />
          <.row_action
            :if={data.user.id != @current_user.id}
            icon="hero-trash"
            title="Delete user"
            destructive
            phx-click="open_delete_modal"
            phx-value-id={data.user.id}
          />
        </:action>
        <:empty>No users found</:empty>
      </.admin_table>
    </div>
    """
  end

  attr :user, :map, required: true

  defp user_cell(assigns) do
    ~H"""
    <div class="flex items-center gap-3">
      <div class="avatar placeholder">
        <div class="bg-primary text-primary-content rounded-full w-12">
          <%= if @user.avatar_url do %>
            <img src={@user.avatar_url} alt={User.label(@user)} />
          <% else %>
            <span class="text-lg">
              {@user |> User.label() |> String.first() |> String.upcase()}
            </span>
          <% end %>
        </div>
      </div>
      <div>
        <div class="font-bold" id={"user-name-#{@user.id}"}>{User.label(@user)}</div>
        <div class="text-sm text-base-content/70">{@user.email}</div>
        <div
          :if={@user.display_name && @user.display_name != User.label(@user)}
          class="text-xs text-base-content/50"
        >
          {@user.display_name}
        </div>
      </div>
    </div>
    """
  end

  attr :user, :map, required: true

  defp auth_cell(assigns) do
    ~H"""
    <span class="font-mono text-sm">{auth_type_text(@user)}</span>
    <span
      :if={second_factor_on?(@user)}
      id={"totp-badge-#{@user.id}"}
      class="badge badge-success badge-sm ml-1"
      title="Two-factor authentication is on"
    >
      2FA
    </span>
    <span
      :if={passkey_count(@user) > 0}
      id={"passkey-badge-#{@user.id}"}
      class="badge badge-ghost badge-sm ml-1"
      title="Passkeys registered"
    >
      {passkey_count(@user)} {if passkey_count(@user) == 1, do: "passkey", else: "passkeys"}
    </span>
    """
  end

  attr :data, :map, required: true

  defp stats_cell(assigns) do
    ~H"""
    <div class="text-sm">
      <div class="flex items-center gap-1">
        <.icon name="hero-inbox-arrow-down" class="w-4 h-4" />
        <span class="font-semibold">{@data.requests_submitted}</span>
        <span class="text-base-content/60">submitted</span>
      </div>
      <div class="flex items-center gap-1">
        <.icon name="hero-check-circle" class="w-4 h-4 text-success" />
        <span class="font-semibold">{@data.requests_approved}</span>
        <span class="text-base-content/60">approved</span>
      </div>
      <div class="flex items-center gap-1">
        <.icon name="hero-x-circle" class="w-4 h-4 text-error" />
        <span class="font-semibold">{@data.requests_rejected}</span>
        <span class="text-base-content/60">rejected</span>
      </div>
    </div>
    """
  end

  defp oidc_user?(%User{oidc_sub: oidc_sub}) when not is_nil(oidc_sub), do: true
  defp oidc_user?(_user), do: false

  defp format_date(nil), do: "Never"
  defp format_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %d, %Y")

  defp role_badge_class("admin"), do: "badge-error"
  defp role_badge_class("user"), do: "badge-primary"
  defp role_badge_class("readonly"), do: "badge-info"
  defp role_badge_class("guest"), do: "badge-warning"
  defp role_badge_class(_), do: "badge-ghost"

  defp auth_type_text(%User{oidc_sub: oidc_sub}) when not is_nil(oidc_sub), do: "OIDC"
  defp auth_type_text(_user), do: "Local"

  defp passkey_count(%{passkeys: passkeys}) when is_list(passkeys), do: length(passkeys)
  defp passkey_count(_user), do: 0

  defp second_factor_on?(user), do: Accounts.totp_enabled?(user) or passkey_count(user) > 0
end
