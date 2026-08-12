defmodule Mydia.MediaServer.Plex.Home do
  @moduledoc """
  Plex Home user discovery.

  Plex Home lets one account own several profiles, which is how self-hosters
  share a server with a household. The admin token can enumerate them and mint
  per-profile tokens, so mapping needs no action from individual users.

  An account with no Plex Home is not an error: it returns an empty list, and
  seeding falls back to a single owner link when nothing is mapped yet. Once
  anything is mapped the fallback stands down, because it cannot tell a
  Home-less account from a bad minute at plex.tv and would overwrite the
  operator's own mapping with the owner's.
  """

  require Logger

  alias Mydia.Accounts
  alias Mydia.MediaServer.Error
  alias Mydia.MediaServer.PlexOAuth
  alias Mydia.MediaServer.SeedResult
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
  When the account has no Plex Home and nothing is mapped yet, a single link
  binds the first admin user to this config using the config's own token.
  """
  @spec seed_links(map(), keyword()) :: {:ok, SeedResult.t()} | {:error, term()}
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
    case Settings.list_media_server_user_links(config.id) do
      # An existing mapping outranks the fallback. The fallback link carries no
      # remote_user_id at all and the upsert replaces that column, so writing it
      # over a deliberate profile mapping would erase which account the operator
      # picked. A 404 from plex.tv (no Home) and a plex.tv blip read identically
      # here, so one unlucky click must not undo their work.
      [_ | _] = existing ->
        {:ok, SeedResult.finish(%SeedResult{already_mapped: Enum.map(existing, &link_label/1)})}

      [] ->
        seed_owner_link(config)
    end
  end

  defp seed_owner_link(config) do
    case Accounts.list_users(role: "admin") do
      [owner | _] ->
        with {:ok, link} <-
               Settings.upsert_media_server_user_link(%{
                 media_server_config_id: config.id,
                 user_id: owner.id,
                 access_token: config.token,
                 enabled: true
               }) do
          {:ok, SeedResult.finish(%SeedResult{linked: [link]})}
        end

      [] ->
        {:error, :no_admin_user}
    end
  end

  defp link_label(%MediaServerUserLink{remote_username: name})
       when is_binary(name) and name != "",
       do: name

  defp link_label(%MediaServerUserLink{remote_user_id: id}) when is_binary(id) and id != "",
    do: id

  defp link_label(_link), do: "an existing mapping"

  defp seed_matched_links(config, home_users, opts) do
    by_username =
      Map.new(Accounts.list_users(), fn user ->
        {String.downcase(user.username), user}
      end)

    home_users
    |> Enum.reduce_while({:ok, %SeedResult{}}, fn home_user, {:ok, result} ->
      username = home_user.username || ""

      case Map.get(by_username, String.downcase(username)) do
        nil -> {:cont, {:ok, result}}
        user -> link_home_user(config, user, home_user, result, opts)
      end
    end)
    |> case do
      {:ok, result} -> {:ok, SeedResult.finish(result)}
      other -> other
    end
  end

  defp link_home_user(config, user, home_user, result, opts) do
    # Skip rather than fall back to the admin token. A link carrying the wrong
    # account's token silently merges two people's watch history, which is
    # precisely what per-user mapping is meant to prevent.
    case token_for(config, home_user.plex_account_id, opts) do
      {:ok, token} ->
        attrs = %{
          media_server_config_id: config.id,
          user_id: user.id,
          remote_user_id: home_user.plex_account_id,
          remote_username: home_user.username,
          access_token: token,
          enabled: true
        }

        write_link(attrs, home_user, result)

      {:error, reason} ->
        Logger.warning(
          "Skipping Plex Home link for #{home_user.username}: " <>
            "could not mint a per-user token (#{inspect(reason)})"
        )

        {:cont, {:ok, result}}
    end
  end

  defp write_link(attrs, home_user, result) do
    case Settings.upsert_media_server_user_link(attrs) do
      {:ok, link} ->
        {:cont, {:ok, SeedResult.add_link(result, link)}}

      # A mapping the operator made by hand outranks rediscovery, and one
      # claimed profile is no reason to abandon the rest of the run.
      {:error, :account_already_mapped} ->
        {:cont, {:ok, SeedResult.add_already_mapped(result, home_user.username)}}

      {:error, _reason} = error ->
        {:halt, error}
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
