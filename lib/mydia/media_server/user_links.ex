defmodule Mydia.MediaServer.UserLinks do
  @moduledoc """
  Reads a media server's accounts and writes the links that map them to Mydia
  users.

  Automatic username matching (`Jellyfin.Users.seed_links/1`,
  `Plex.Home.seed_links/2`) only ever links accounts whose names already agree,
  so an operator whose media server username differs from their Mydia username
  needs a way to pair the two by hand. This module is that path, and it is
  deliberately the only one: the account being linked always comes from a list
  the server just reported, never from submitted form data.

  Two rules exist here because breaking either one files one person's watch
  history under another person's name:

    * A link's `remote_user_id` and `access_token` must always name the same
      account. `Settings.upsert_media_server_user_link/1` replaces both columns
      on conflict, so every write states both, and the token is derived from the
      account being written rather than carried over from the row's old value.

    * Which of the two fields carries the identity is the provider's decision.
      Jellyfin has no per-user tokens, so the GUID is the identity and the token
      is explicitly nil. On Plex the token *is* the identity, so it is minted for
      the chosen account and a failed mint means no write at all.

  A third rule, that one remote account belongs to at most one Mydia user, is
  enforced by `Settings.upsert_media_server_user_link/1` itself rather than here,
  because discovery writes links without going through this module.
  """

  alias Mydia.MediaServer.Client.Jellyfin, as: JellyfinClient
  alias Mydia.MediaServer.Error
  alias Mydia.MediaServer.Jellyfin.Users, as: JellyfinUsers
  alias Mydia.MediaServer.Plex.Home, as: PlexHome
  alias Mydia.MediaServer.RemoteAccount
  alias Mydia.MediaServer.SeedResult
  alias Mydia.Repo
  alias Mydia.Settings
  alias Mydia.Settings.MediaServerUserLink

  @type config :: Mydia.Settings.MediaServerConfig.t()
  @type reason :: Error.t() | {:unsupported_provider, atom()} | term()

  @doc """
  Lists the accounts a server reports, normalised for the mapping picker.
  """
  @spec list_remote_accounts(config(), keyword()) ::
          {:ok, [RemoteAccount.t()]} | {:error, reason()}
  def list_remote_accounts(config, opts \\ [])

  def list_remote_accounts(%{type: :jellyfin} = config, _opts) do
    with {:ok, users} <- JellyfinClient.list_users(config) do
      {:ok, Enum.map(users, &%RemoteAccount{id: to_string(&1.id), name: &1.name})}
    end
  end

  def list_remote_accounts(%{type: :plex} = config, opts) do
    with {:ok, users} <- PlexHome.list_users(config, opts) do
      {:ok,
       Enum.map(
         users,
         &%RemoteAccount{
           id: to_string(&1.plex_account_id),
           name: &1.username,
           admin?: &1.admin?
         }
       )}
    end
  end

  def list_remote_accounts(%{type: type}, _opts), do: {:error, {:unsupported_provider, type}}

  @doc """
  Links every account whose name matches a Mydia username.

  This is the automatic pass, offered in the UI as "Discover accounts". It leaves
  accounts with no name match alone for the operator to map by hand, and leaves
  accounts another Mydia user is already mapped to alone as well, reporting them
  in the result rather than reassigning them.
  """
  @spec discover(config(), keyword()) :: {:ok, SeedResult.t()} | {:error, reason()}
  def discover(config, opts \\ [])

  def discover(%{type: :jellyfin} = config, _opts), do: JellyfinUsers.seed_links(config)
  def discover(%{type: :plex} = config, opts), do: PlexHome.seed_links(config, opts)
  def discover(%{type: type}, _opts), do: {:error, {:unsupported_provider, type}}

  @doc """
  Points one Mydia user at one remote account.

  Every column is written from a value the caller controls: the config, the
  Mydia user id, and the account the server reported. Nothing is cast from
  submitted params, so no request can set or clear the link's credential.

  ## Options

    * `:replaces` - the link the editor is rewriting. When it belongs to a
      different Mydia user, the save is a *move*: that row is deleted in the same
      transaction, so its account is never claimed twice.
    * any option `Plex.Home.token_for/3` accepts.
  """
  @spec link_user(config(), binary(), RemoteAccount.t(), keyword()) ::
          {:ok, MediaServerUserLink.t()} | {:error, reason()}
  def link_user(config, user_id, account, opts \\ [])

  def link_user(config, user_id, %RemoteAccount{} = account, opts) do
    # One write site, and the token it stores comes only from the account being
    # written. That is what keeps `remote_user_id` and `access_token` naming the
    # same account: there is no path that reaches the upsert carrying a token
    # the previous row happened to hold.
    #
    # The token is minted before the transaction opens, because it is an HTTP
    # round trip to plex.tv and nothing should hold a write lock through that.
    with {:ok, access_token} <- token_for(config, account, opts) do
      write_link(config, user_id, account, access_token, Keyword.get(opts, :replaces))
    end
  end

  defp write_link(config, user_id, account, access_token, replaces) do
    Repo.transaction(fn ->
      with :ok <- release_claim(config, user_id, replaces),
           {:ok, link} <- upsert(config, user_id, account, access_token) do
        link
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # Reassigning a mapping to a different Mydia user moves it rather than copying
  # it: the row that held the account goes away in the same transaction that
  # writes the new one. That keeps the claim check in
  # `Settings.upsert_media_server_user_link/1` absolute, with no "except when the
  # editor says so" hole for a caller to lean on.
  defp release_claim(_config, _user_id, nil), do: :ok

  defp release_claim(config, user_id, %MediaServerUserLink{} = replaces) do
    if replaces.media_server_config_id == config.id and replaces.user_id != user_id do
      with {:ok, _deleted} <- Settings.delete_media_server_user_link(replaces), do: :ok
    else
      :ok
    end
  end

  # Jellyfin issues no per-user tokens; the server's own API key does the talking
  # for every linked account, so the GUID is the entire identity. The nil is
  # deliberate rather than omitted, because the upsert replaces the token column
  # either way and a token left behind here could only be another account's.
  defp token_for(%{type: :jellyfin}, _account, _opts), do: {:ok, nil}

  # On Plex the identity IS the token, so it is minted for the account being
  # written, in the same operation. Reusing whatever the row already held would
  # leave the link claiming account B while holding account A's credential, and
  # the sync would then file A's history under B.
  #
  # A mint that fails writes nothing. A Plex link with an account id and no token
  # cannot sync at all, so half-written is strictly worse than untouched.
  defp token_for(%{type: :plex} = config, account, opts) do
    PlexHome.token_for(config, account.id, opts)
  end

  defp token_for(%{type: type}, _account, _opts), do: {:error, {:unsupported_provider, type}}

  defp upsert(config, user_id, %RemoteAccount{} = account, access_token) do
    Settings.upsert_media_server_user_link(%{
      media_server_config_id: config.id,
      user_id: user_id,
      remote_user_id: account.id,
      remote_username: account.name,
      access_token: access_token,
      enabled: true
    })
  end
end
