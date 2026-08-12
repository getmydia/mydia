defmodule MydiaWeb.AdminMediaServersLive.UserLinkComponents do
  @moduledoc false
  use MydiaWeb, :html

  alias Mydia.MediaServer.RemoteAccount

  @doc """
  Renders the user mapping section of a media server card.

  Watched sync runs per user and skips anyone without a mapping, so this is
  where an operator sees who is actually covered, and fixes the accounts whose
  media server username does not match their Mydia one.
  """
  attr :server, :map, required: true
  attr :user_links, :map, required: true
  attr :mydia_users, :list, required: true

  def user_links_section(assigns) do
    assigns = assign(assigns, :links, Map.get(assigns.user_links, assigns.server.id, []))

    ~H"""
    <div
      :if={per_user_accounts?(@server.type)}
      id={"user-mapping-#{@server.id}"}
      class="pt-3 border-t border-base-200 space-y-2"
    >
      <div class="flex flex-wrap items-center justify-between gap-2">
        <span class="text-sm font-medium text-base-content/70">User mapping</span>

        <div class="join">
          <button
            type="button"
            class="btn btn-xs btn-ghost join-item gap-1"
            phx-click="user_link_discover"
            phx-value-id={@server.id}
            title="Match accounts whose username already agrees"
          >
            <.icon name="hero-arrow-path" class="w-3.5 h-3.5" /> Discover
          </button>
          <button
            type="button"
            class="btn btn-xs btn-ghost join-item gap-1"
            phx-click="user_link_new"
            phx-value-id={@server.id}
            title="Map an account to a Mydia user by hand"
          >
            <.icon name="hero-plus" class="w-3.5 h-3.5" /> Add mapping
          </button>
        </div>
      </div>

      <div class="space-y-1.5">
        <div
          :for={link <- @links}
          id={"user-link-#{link.id}"}
          class="flex items-center gap-2 bg-base-200 rounded-lg px-3 py-2"
        >
          <div class="flex-1 min-w-0 text-sm">
            <div class="flex items-center gap-1.5 flex-wrap">
              <span class="font-medium truncate">{remote_label(link)}</span>
              <.icon name="hero-arrow-right" class="w-3.5 h-3.5 opacity-50 shrink-0" />
              <span class="truncate">{username_for(@mydia_users, link.user_id)}</span>
              <span :if={not link.enabled} class="badge badge-ghost badge-xs">Paused</span>
            </div>
          </div>

          <div class="join ml-auto">
            <button
              type="button"
              class="btn btn-xs btn-ghost join-item"
              phx-click="user_link_edit"
              phx-value-id={link.id}
              title="Edit"
            >
              <.icon name="hero-pencil" class="w-3.5 h-3.5" />
            </button>
            <button
              type="button"
              class="btn btn-xs btn-ghost join-item text-error"
              phx-click="user_link_delete"
              phx-value-id={link.id}
              data-confirm="Remove this mapping? Watched sync will skip this user until it is mapped again."
              title="Remove"
            >
              <.icon name="hero-trash" class="w-3.5 h-3.5" />
            </button>
          </div>
        </div>

        <p :if={@links == []} class="text-xs text-base-content/50">
          Nobody is mapped yet, so watched sync has no accounts to read. Discover matches accounts
          by username; add a mapping by hand when the names differ.
        </p>
      </div>
    </div>
    """
  end

  @doc """
  Renders the user mapping editor.

  Both fields are pickers rather than text inputs: the value a mapping stores is
  an account id the server issued, not something worth typing by hand.
  """
  attr :form, :any, required: true
  attr :mode, :atom, required: true
  attr :server, :map, required: true
  attr :accounts, :list, required: true
  attr :mydia_users, :list, required: true

  def user_link_modal(assigns) do
    ~H"""
    <div class="modal modal-open" id="user-link-modal">
      <div class="modal-box max-w-xl">
        <.form for={@form} id="user-link-form" phx-submit="user_link_save">
          <%!-- Header --%>
          <div class="flex items-center gap-3 mb-5">
            <div class="w-10 h-10 rounded-xl bg-primary/20 flex items-center justify-center">
              <.icon
                name={if(@mode == :new, do: "hero-plus-circle", else: "hero-pencil-square")}
                class="w-5 h-5 text-primary"
              />
            </div>
            <div>
              <h3 class="font-bold text-lg">
                {if @mode == :new, do: "Add User Mapping", else: "Edit User Mapping"}
              </h3>
              <p class="text-sm text-base-content/60">
                Pair a Mydia user with their account on {@server.name}
              </p>
            </div>
          </div>

          <div class="space-y-4">
            <.input
              field={@form[:user_id]}
              type="select"
              label="Mydia user"
              options={user_options(@mydia_users)}
              required
            />

            <.input
              field={@form[:remote_user_id]}
              type="select"
              label={"Account on #{@server.name}"}
              prompt="Choose an account"
              options={account_options(@accounts)}
              hint={account_hint(@server.type)}
              required
            />
          </div>

          <%!-- Modal Actions --%>
          <div class="modal-action mt-6 pt-4 border-t border-base-300">
            <button type="button" class="btn btn-ghost" phx-click="close_user_link_modal">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary gap-2">
              <.icon name="hero-check" class="w-4 h-4" />
              {if @mode == :new, do: "Add Mapping", else: "Save Changes"}
            </button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop bg-black/50" phx-click="close_user_link_modal"></div>
    </div>
    """
  end

  # Both current providers give each household member their own account. A new
  # provider without that model would need its own mapping story, so it opts in
  # here rather than inheriting one that cannot work.
  defp per_user_accounts?(type), do: type in [:plex, :jellyfin]

  defp user_options(users), do: Enum.map(users, &{&1.username, &1.id})

  defp account_options(accounts) do
    Enum.map(accounts, fn account ->
      label = RemoteAccount.label(account)

      {if(account.admin?, do: "#{label} (owner)", else: label), account.id}
    end)
  end

  defp account_hint(:plex) do
    "Plex Home profiles. Saving mints a token for the profile you pick, so its watch history stays its own."
  end

  defp account_hint(:jellyfin), do: "Accounts on the Jellyfin server."
  defp account_hint(_type), do: nil

  # Plex's owner fallback links a user with a token and no account name at all,
  # so the row has to stay readable without one.
  defp remote_label(%{remote_username: name}) when is_binary(name) and name != "", do: name
  defp remote_label(%{remote_user_id: id}) when is_binary(id) and id != "", do: id
  defp remote_label(_link), do: "unnamed account"

  defp username_for(users, user_id) do
    case Enum.find(users, &(&1.id == user_id)) do
      nil -> "unknown user"
      user -> user.username
    end
  end
end
