defmodule Mydia.MediaServer.UserLinks do
  @moduledoc """
  Reads a media server's accounts and writes the links that map them to Mydia
  users.

  Automatic username matching (`discover/2`) only ever links accounts whose names
  already agree, so an operator whose media server username differs from their
  Mydia username needs a way to pair the two by hand. `apply_mapping/3` is that
  path, and it is deliberately the only one: the account being linked always
  comes from a list the server just reported, never from submitted form data.

  Two rules exist here because breaking either one files one person's watch
  history under another person's name:

    * A link's `remote_user_id` and `access_token` must always name the same
      account. `Settings.upsert_media_server_user_link/2` replaces both columns
      on conflict, so every write states both, and the token is either minted for
      the account being written or carried over from a row that named that same
      account and the same user.

    * Which of the two fields carries the identity is the provider's decision.
      Jellyfin has no per-user tokens, so the GUID is the identity and the token
      is explicitly nil. On Plex the token *is* the identity, so it is minted for
      the chosen account and a failed mint means no write at all.

  A third rule, that one remote account belongs to at most one Mydia user, is
  enforced by `Mydia.Settings.ServiceConfigs` at the write itself rather than
  here, because seeding writes links without going through `apply_mapping/3`.
  """

  alias Mydia.MediaServer.Client.Jellyfin, as: JellyfinClient
  alias Mydia.MediaServer.Error
  alias Mydia.MediaServer.Jellyfin.Users, as: JellyfinUsers
  alias Mydia.MediaServer.Plex.Home, as: PlexHome
  alias Mydia.MediaServer.RemoteAccount
  alias Mydia.MediaServer.SeedResult
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

  This is the automatic pass `Mydia.Jobs.MediaServerLinkSeed` runs on a config
  save and on the scheduler's first look at a server nobody has seeded. It leaves
  accounts with no name match alone for the operator to map by hand, and leaves
  accounts another Mydia user is already mapped to alone as well, reporting them
  in the result rather than reassigning them.

  It also leaves alone every Mydia user who already has a mapping here, which is
  what `only_new: true` below forces and what no caller may turn off. Discovery
  matches by username; a hand-made mapping exists precisely when the two names
  differ, so a discovery pass allowed to write over one would repoint it at
  whichever account merely shares the Mydia user's name, and that account is
  someone else's. Re-pointing is `apply_mapping/3`'s job, and that path mints a
  fresh credential for the account being chosen.
  """
  @spec discover(config(), keyword()) :: {:ok, SeedResult.t()} | {:error, reason()}
  def discover(config, opts \\ [])

  def discover(%{type: :jellyfin} = config, opts),
    do: JellyfinUsers.seed_links(config, only_new(opts))

  def discover(%{type: :plex} = config, opts), do: PlexHome.seed_links(config, only_new(opts))
  def discover(%{type: type}, _opts), do: {:error, {:unsupported_provider, type}}

  defp only_new(opts), do: Keyword.put(opts, :only_new, true)

  @doc """
  Applies an operator-chosen account-to-user mapping for one server.

  `mapping` maps a remote account id to a Mydia user id, or to `nil` for "do not
  sync this account". The whole mapping replaces whatever the config had, so
  this unlinks as well as links: an account the operator left blank, and an
  account that has disappeared from the server, both lose their link.

  Every column is written from a value this function controls: the config, a
  Mydia user id, and an account the server itself just reported. Nothing is cast
  from submitted params, so no request can set or clear a link's credential, and
  an account id the server does not list is dropped rather than written.

  Every network round trip happens before the database is touched, and the
  writes then land in one transaction. On SQLite a write transaction locks the
  whole database, so a plex.tv call inside one would stall every other writer
  for its duration; doing the network first also means a mint that fails leaves
  the existing mapping exactly as it was.

  ## Options

    * any option `Plex.Home.token_for/3` accepts.
  """
  @spec apply_mapping(config(), %{optional(String.t()) => binary() | nil}, keyword()) ::
          {:ok, [MediaServerUserLink.t()]} | {:error, reason()}
  def apply_mapping(config, mapping, opts \\ []) do
    with :ok <- ensure_one_account_per_user(mapping),
         {:ok, accounts} <- list_remote_accounts(config, opts) do
      by_account =
        Map.new(Settings.list_media_server_user_links(config.id), &{&1.remote_user_id, &1})

      desired =
        for account <- accounts,
            user_id = Map.get(mapping, account.id),
            not is_nil(user_id),
            do: {account, user_id}

      with {:ok, entries} <- resolve_entries(config, desired, by_account, opts) do
        Settings.replace_media_server_user_links(config.id, entries)
      end
    end
  end

  # Two accounts aimed at one Mydia user would not fail on its own:
  # media_server_user_links is unique on (config, user), so the second would
  # quietly replace the first and leave an account displaying as linked while
  # syncing nothing.
  #
  # The other direction, two Mydia users on one account, cannot arise here
  # because `mapping` is keyed by account id. `replace_media_server_user_links/2`
  # checks it anyway, since it is the writer and not every caller has to be this
  # one.
  defp ensure_one_account_per_user(mapping) do
    user_ids = mapping |> Map.values() |> Enum.reject(&is_nil/1)

    if length(user_ids) == length(Enum.uniq(user_ids)),
      do: :ok,
      else: {:error, :duplicate_user}
  end

  # Resolves the whole mapping to plain attrs, doing every token mint up front.
  # Nothing is written here, so an error means the stored links are untouched.
  defp resolve_entries(config, desired, by_account, opts) do
    desired
    |> Enum.reduce_while({:ok, []}, fn {account, user_id}, {:ok, acc} ->
      case token_for(config, account, user_id, by_account, opts) do
        {:ok, token} -> {:cont, {:ok, [link_attrs(config, account, user_id, token) | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      other -> other
    end
  end

  # Reuses the token already stored against this exact (account, user) pair.
  # Re-minting would cost a plex.tv profile switch per profile on every save of
  # a form the operator may not have changed at all. Matching on both halves is
  # what keeps the reuse safe: a token is only carried over when the row it came
  # from named the same account, so it can never end up beside a different one.
  defp token_for(config, account, user_id, by_account, opts) do
    case Map.get(by_account, account.id) do
      %{user_id: ^user_id, access_token: token} when is_binary(token) and token != "" ->
        {:ok, token}

      _ ->
        mint_token(config, account, opts)
    end
  end

  # Jellyfin issues no per-user tokens; the server's own API key does the talking
  # for every linked account, so the GUID is the entire identity. The nil is
  # deliberate rather than omitted, because the upsert replaces the token column
  # either way and a token left behind here could only be another account's.
  defp mint_token(%{type: :jellyfin}, _account, _opts), do: {:ok, nil}

  # On Plex the identity IS the token, so it is minted for the account being
  # written. Reusing whatever the row already held would leave the link claiming
  # account B while holding account A's credential, and the sync would then file
  # A's history under B.
  #
  # A mint that fails writes nothing. A Plex link with an account id and no token
  # cannot sync at all, so half-written is strictly worse than untouched.
  defp mint_token(%{type: :plex} = config, account, opts) do
    PlexHome.token_for(config, account.id, opts)
  end

  defp mint_token(%{type: type}, _account, _opts), do: {:error, {:unsupported_provider, type}}

  # The one shape a link is ever written in, whichever producer built it: a
  # Mydia user bound to a remote account, holding that same account's credential
  # or none at all.
  defp link_attrs(config, %RemoteAccount{} = account, user_id, access_token) do
    %{
      media_server_config_id: config.id,
      user_id: user_id,
      remote_user_id: account.id,
      remote_username: account.name,
      access_token: access_token,
      enabled: true
    }
  end
end
