defmodule Mydia.MediaServer.Plex.Home do
  @moduledoc """
  Plex Home user discovery.

  Plex Home lets one account own several profiles, which is how self-hosters
  share a server with a household. The admin token can enumerate them and mint
  per-profile tokens, so mapping needs no action from individual users.

  An account with no Plex Home is not an error: it returns an empty list and
  the caller falls back to a single owner link.
  """

  require Logger

  alias Mydia.Accounts
  alias Mydia.MediaServer.Error
  alias Mydia.MediaServer.PlexOAuth
  alias Mydia.Settings
  alias Mydia.Settings.MediaServerUserLink

  @plex_api_base "https://plex.tv/api/v2"

  @type home_user :: %{
          plex_account_id: String.t(),
          username: String.t(),
          admin?: boolean()
        }

  @spec list_users(map(), keyword()) :: {:ok, [home_user()]} | {:error, Error.t()}
  def list_users(config, opts \\ []) do
    base = Keyword.get(opts, :plex_tv_base, @plex_api_base)

    (base <> "/home/users")
    |> Req.get(headers: headers(config), retry: false)
    |> case do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body |> get_users() |> Enum.map(&parse_user/1)}

      # No Plex Home on this account.
      {:ok, %{status: 404}} ->
        {:ok, []}

      {:ok, %{status: s}} when s in [401, 403] ->
        {:error, Error.auth("HTTP #{s}")}

      {:ok, %{status: s}} ->
        {:error, Error.unexpected("HTTP #{s}")}

      {:error, e} ->
        {:error, Error.unreachable(Exception.message(e))}
    end
  end

  @doc """
  Seeds `media_server_user_links` from Plex Home users.

  Each Home profile is matched to a Mydia user by case-insensitive username.
  When the account has no Plex Home, a single link binds the first admin user
  to this config using the config's own token.
  """
  @spec seed_links(map(), keyword()) :: {:ok, [MediaServerUserLink.t()]} | {:error, term()}
  def seed_links(config, opts \\ []) do
    case list_users(config, opts) do
      {:ok, []} ->
        seed_owner_fallback(config)

      {:ok, home_users} ->
        seed_matched_links(config, home_users, opts)

      {:error, _} = error ->
        error
    end
  end

  defp seed_owner_fallback(config) do
    case Accounts.list_users(role: "admin") do
      [owner | _] ->
        with {:ok, link} <-
               Settings.upsert_media_server_user_link(%{
                 media_server_config_id: config.id,
                 user_id: owner.id,
                 access_token: config.token,
                 enabled: true
               }) do
          {:ok, [link]}
        end

      [] ->
        {:error, :no_admin_user}
    end
  end

  @doc """
  Applies an operator-chosen profile-to-user mapping.

  `mapping` maps a Plex Home `plex_account_id` to a Mydia user id, or to `nil`
  for "do not sync this profile".

  `seed_links/2` can only ever link a profile whose name equals a Mydia
  username. Self-hosters name Plex profiles after people and their Mydia
  account `admin`, so on most installs that matches nothing, leaves zero links,
  and watched sync sits skipped forever with no operator recourse. This is the
  recourse.

  Links whose profile is unmapped, or whose profile has disappeared from Plex
  Home, are removed, so this unlinks as well as links.

  Every plex.tv round trip happens before the database is touched, and the
  writes then land in one transaction. Minting is one profile switch per newly
  linked profile, so a transaction held open across them would lock the whole
  SQLite database for the length of a network call; doing the network first also
  means a mint that fails leaves the existing mapping exactly as it was.
  """
  @spec apply_mapping(map(), %{optional(String.t()) => binary() | nil}, keyword()) ::
          {:ok, [MediaServerUserLink.t()]} | {:error, term()}
  def apply_mapping(config, mapping, opts \\ []) do
    with :ok <- validate_mapping(mapping),
         {:ok, home_users} <- list_users(config, opts) do
      by_account =
        config.id
        |> Settings.list_media_server_user_links()
        |> Map.new(&{&1.plex_account_id, &1})

      desired =
        for home_user <- home_users,
            user_id = Map.get(mapping, home_user.plex_account_id),
            not is_nil(user_id),
            do: {home_user, user_id}

      with {:ok, entries} <- resolve_entries(config, desired, by_account, opts) do
        Settings.replace_media_server_user_links(config.id, entries)
      end
    end
  end

  # Two profiles aimed at one Mydia user would not fail: media_server_user_links
  # is unique on (config, user), so the second would quietly replace the first
  # and leave a profile displaying as linked while syncing nothing.
  defp validate_mapping(mapping) do
    user_ids = mapping |> Map.values() |> Enum.reject(&is_nil/1)

    if length(user_ids) == length(Enum.uniq(user_ids)),
      do: :ok,
      else: {:error, :duplicate_user}
  end

  # Resolves the whole mapping to plain attrs, doing every token mint up front.
  # Nothing is written here, so an error means the stored links are untouched.
  defp resolve_entries(config, desired, by_account, opts) do
    desired
    |> Enum.reduce_while({:ok, []}, fn {home_user, user_id}, {:ok, acc} ->
      case token_for_mapping(config, home_user, user_id, by_account, opts) do
        {:ok, token} ->
          {:cont, {:ok, [link_attrs(config, home_user, user_id, token) | acc]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      other -> other
    end
  end

  # Reuses the token already on a link that points at this same user. Re-minting
  # would cost a plex.tv profile switch per profile on every save of a form the
  # operator may not have changed at all.
  defp token_for_mapping(config, home_user, user_id, by_account, opts) do
    case Map.get(by_account, home_user.plex_account_id) do
      %{user_id: ^user_id, access_token: token} when is_binary(token) and token != "" ->
        {:ok, token}

      _ ->
        token_for(config, home_user.plex_account_id, opts)
    end
  end

  # The one shape a link is ever written in. Both the auto-matcher and the
  # manual mapping build it here so a link means the same thing however it was
  # made: a Mydia user bound to a Plex profile by that profile's own token.
  defp link_attrs(config, home_user, user_id, token) do
    %{
      media_server_config_id: config.id,
      user_id: user_id,
      plex_account_id: home_user.plex_account_id,
      plex_username: home_user.username,
      access_token: token,
      enabled: true
    }
  end

  defp link_user(config, home_user, user_id, opts) do
    with {:ok, token} <- token_for(config, home_user.plex_account_id, opts) do
      Settings.upsert_media_server_user_link(link_attrs(config, home_user, user_id, token))
    end
  end

  defp seed_matched_links(config, home_users, opts) do
    by_username =
      Map.new(Accounts.list_users(), fn user ->
        {String.downcase(user.username), user}
      end)

    home_users
    |> Enum.reduce_while({:ok, []}, fn home_user, {:ok, acc} ->
      username = home_user.username || ""

      case Map.get(by_username, String.downcase(username)) do
        nil ->
          {:cont, {:ok, acc}}

        user ->
          # Skip rather than fall back to the admin token. A link carrying the
          # wrong account's token silently merges two people's watch history,
          # which is precisely what per-user mapping is meant to prevent.
          case link_user(config, home_user, user.id, opts) do
            {:ok, link} ->
              {:cont, {:ok, [link | acc]}}

            {:error, %Error{} = reason} ->
              Logger.warning(
                "Skipping Plex Home link for #{home_user.username}: " <>
                  "could not mint a per-user token (#{inspect(reason)})"
              )

              {:cont, {:ok, acc}}

            {:error, _} = err ->
              {:halt, err}
          end
      end
    end)
    |> case do
      {:ok, links} -> {:ok, Enum.reverse(links)}
      other -> other
    end
  end

  @doc """
  Mints a token scoped to one Plex Home user by switching to that profile.

  This is what makes per-user mapping mean anything. The admin account token can
  enumerate home users, but reading a given profile's watch state requires that
  profile's own token, so seeding links with the admin token would give every
  Mydia user the admin's watch state and reproduce the merge bug in a new place.

  Returns an error rather than falling back to the admin token when a switch
  fails or returns no token: no link is better than a link pointing at someone
  else's history.
  """
  @spec token_for(map(), String.t(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def token_for(config, plex_account_id, opts \\ []) do
    base = Keyword.get(opts, :plex_tv_base, @plex_api_base)

    (base <> "/home/users/#{plex_account_id}/switch")
    |> Req.post(headers: headers(config), retry: false)
    |> case do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        extract_token(body, plex_account_id)

      {:ok, %{status: s}} when s in [401, 403] ->
        {:error, Error.auth("HTTP #{s}")}

      {:ok, %{status: s}} ->
        {:error, Error.unexpected("HTTP #{s}")}

      {:error, e} ->
        {:error, Error.unreachable(Exception.message(e))}
    end
  end

  defp extract_token(%{"authToken" => token}, _id) when is_binary(token) and token != "",
    do: {:ok, token}

  defp extract_token(%{"authentication_token" => token}, _id)
       when is_binary(token) and token != "",
       do: {:ok, token}

  defp extract_token(_body, id),
    do: {:error, Error.unexpected("switch to home user #{id} returned no token")}

  defp get_users(%{"users" => users}) when is_list(users), do: users
  defp get_users(users) when is_list(users), do: users
  defp get_users(_), do: []

  defp parse_user(user) do
    %{
      plex_account_id: to_string(user["id"]),
      username: user["username"] || user["title"],
      admin?: user["admin"] == true
    }
  end

  defp headers(config) do
    [
      {"X-Plex-Token", config.token},
      {"X-Plex-Client-Identifier", PlexOAuth.client_identifier()},
      {"Accept", "application/json"}
    ]
  end
end
