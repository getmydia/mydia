defmodule MydiaWeb.AdminMediaServersLive.AccountMappingComponents do
  @moduledoc false
  use MydiaWeb, :html

  alias Mydia.Accounts.User
  alias Mydia.MediaServer.RemoteAccount

  @doc """
  Renders the account mapping modal.

  Auto-matching links an account only when its name equals a Mydia username.
  People name Jellyfin accounts after people and their Mydia
  account `admin`, so on most installs nothing matches and watched sync sits
  skipped with no way out. This is the way out.
  """
  attr :config, :map, required: true
  attr :state, :any, required: true
  attr :accounts, :list, default: []
  attr :users, :list, default: []
  attr :mapping, :map, default: %{}
  attr :saving, :boolean, default: false

  def account_mapping_modal(assigns) do
    ~H"""
    <.admin_modal
      id="account-mapping-modal"
      icon="hero-user-group"
      title={account_heading(@config)}
      subtitle={account_intro(@config)}
      on_close="close_account_mapping_modal"
    >
      <div class="mt-5">
        <%= case @state do %>
          <% :loading -> %>
            <div
              id="account-mapping-loading"
              class="flex items-center justify-center gap-3 py-10 text-sm text-base-content/70"
            >
              <span class="loading loading-spinner loading-sm"></span>
              {account_loading_message(@config)}
            </div>
          <% {:error, message} -> %>
            <div id="account-mapping-error" class="alert alert-error">
              <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
              <span>{message}</span>
            </div>
          <% :ready -> %>
            <%= if @accounts == [] do %>
              <div id="account-mapping-empty" class="text-center py-10">
                <p class="text-sm text-base-content/70">
                  {account_empty_message(@config)}
                </p>
              </div>
            <% else %>
              <form id="account-mapping-form" phx-submit="save_account_mapping">
                <div class="flex items-center justify-between mb-2">
                  <span class="text-sm font-medium">
                    {length(@accounts)} {found_label(@config, @accounts)}
                  </span>
                  <span class="text-xs text-base-content/50">Mydia user</span>
                </div>

                <div class="flex flex-col gap-2">
                  <div
                    :for={account <- @accounts}
                    id={"account-#{account.id}"}
                    class="flex flex-col gap-2 rounded-lg bg-base-200 px-3 py-2 sm:flex-row sm:items-center sm:justify-between"
                  >
                    <div class="flex items-center gap-2 min-w-0">
                      <.icon name="hero-user-circle" class="w-4 h-4 text-base-content/50" />
                      <%!-- Falls back to the account id: both servers allow a
                        nameless account, and an unlabelled row is worse than a
                        raw id when the operator has to pick one. --%>
                      <span class="truncate text-sm font-medium">
                        {RemoteAccount.label(account)}
                      </span>
                      <span :if={account.admin?} class="badge badge-xs badge-warning">owner</span>
                    </div>
                    <div class="sm:w-56">
                      <.input
                        type="select"
                        id={"account-select-#{account.id}"}
                        name={"mapping[#{account.id}]"}
                        value={Map.get(@mapping, account.id)}
                        options={user_options(@users)}
                        class="select select-sm select-bordered w-full"
                      />
                    </div>
                  </div>
                </div>

                <.admin_modal_actions>
                  <button
                    type="button"
                    class="btn btn-ghost"
                    phx-click="close_account_mapping_modal"
                  >
                    Cancel
                  </button>
                  <button
                    type="submit"
                    id="account-mapping-save"
                    class="btn btn-primary gap-2"
                    disabled={@saving}
                  >
                    <%= if @saving do %>
                      <span class="loading loading-spinner loading-sm"></span> Saving...
                    <% else %>
                      <.icon name="hero-check" class="w-4 h-4" /> Save links
                    <% end %>
                  </button>
                </.admin_modal_actions>
              </form>
            <% end %>
        <% end %>
      </div>
    </.admin_modal>
    """
  end

  # "Don't sync" carries the empty string so an unmapped account round-trips as
  # a present-but-blank param rather than vanishing from the form payload, which
  # is what lets the save path tell "unlink this" apart from "never asked".
  defp user_options(users) do
    # `User.label/1` rather than the raw username: an OIDC-provisioned account
    # has none, and rendered as a blank option the operator could not tell
    # which account they were selecting. SSO accounts cannot be name-matched,
    # so hand-mapping here is the only way they are ever linked at all.
    [{"Don't sync", ""} | Enum.map(users, &{User.label(&1), &1.id})]
  end

  # The copy explains a real difference from token-based providers: Jellyfin has
  # no per-user tokens and the server API key reads each account's state.
  defp account_heading(%{type: :jellyfin}), do: "Jellyfin accounts"
  defp account_heading(_config), do: "Accounts"

  defp account_intro(_config) do
    "Choose which Mydia user each Jellyfin account syncs watched status with. " <>
      "Jellyfin issues no per-user tokens, so the server API key reads each account " <>
      "and the mapping is what keeps histories apart."
  end

  defp account_loading_message(_config), do: "Asking this server for its accounts..."

  defp account_empty_message(_config) do
    "This Jellyfin server reported no accounts, so there is nothing to map yet."
  end

  defp found_label(_config, [_]), do: "account found"
  defp found_label(_config, _accounts), do: "accounts found"
end
