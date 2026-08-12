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
  operator's own mapping with the owner's. The fallback also stands down when
  this install has more than one admin, because `config.token` belongs to
  whoever ran OAuth and the first admin by query order need not be that person.
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
  binds the sole admin user to this config using the config's own token.

  ## Options

    * `:only_new` - never touch a Mydia user who already has a link on this
      server, reporting them as already mapped instead. Both callers pass it:
      matching by username is how a mapping the operator made by hand, pairing
      a Mydia user with a differently named remote account, used to get
      repointed at the account that merely shares the name.
    * `:plex_tv_base` - see `token_for/3`.
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

  # The fallback link carries `config.token`, which is the credential of
  # whoever ran OAuth. With a single admin that is necessarily the same person.
  # With two or more it is a guess, and a wrong guess binds admin A's Mydia
  # account to admin B's Plex watch state, so nothing is written and the
  # operator is told to pair the accounts in the editor instead.
  defp seed_owner_link(config) do
    case Accounts.list_users(role: "admin") do
      [owner] ->
        with {:ok, link} <-
               Settings.upsert_media_server_user_link(%{
                 media_server_config_id: config.id,
                 user_id: owner.id,
                 access_token: config.token,
                 enabled: true
               }) do
          {:ok, SeedResult.finish(%SeedResult{linked: [link], owner_fallback: :linked})}
        end

      [_ | _] ->
        {:ok, SeedResult.finish(%SeedResult{owner_fallback: :ambiguous})}

      [] ->
        {:error, :no_admin_user}
    end
  end

  defp link_label(%MediaServerUserLink{} = link), do: MediaServerUserLink.display_name(link)

  # Same label, for the race where the write is refused rather than the
  # pre-check catching it. `attrs` is the row we tried to write, so it names the
  # pair whose existing link we want to report.
  defp existing_label(%{media_server_config_id: config_id, user_id: user_id}) do
    case Settings.get_media_server_user_link(config_id, user_id) do
      %MediaServerUserLink{} = link -> link_label(link)
      nil -> "an existing mapping"
    end
  end

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
    case existing_link(config, user, opts) do
      # Reported under the account the operator actually mapped, not under the
      # profile that merely shares this Mydia user's name. Naming the latter
      # would tell them a mapping was kept for an account nobody is mapped to.
      %MediaServerUserLink{} = link ->
        {:cont, {:ok, SeedResult.add_already_mapped(result, link_label(link))}}

      nil ->
        mint_and_write(config, user, home_user, result, opts)
    end
  end

  # Looked up before minting rather than only at the write. Minting is a plex.tv
  # round trip per profile, and a config save on a server whose mappings are all
  # in place would otherwise spend one on every household member only to have
  # each write refused. `Settings.upsert_media_server_user_link/2` refuses them
  # anyway; this is the cheap path, not the guarantee.
  defp existing_link(config, user, opts) do
    if Keyword.get(opts, :only_new, false) do
      Settings.get_media_server_user_link(config.id, user.id)
    end
  end

  defp mint_and_write(config, user, home_user, result, opts) do
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

        write_link(attrs, home_user, result, opts)

      # Recorded, not merely logged. A failed mint is plex.tv having a bad
      # minute, and a pass that ends this way is unfinished: reporting it as an
      # ordinary empty result made it indistinguishable from "every profile is
      # already mapped", which is the difference between retrying later and
      # never trying again.
      {:error, reason} ->
        Logger.warning(
          "Skipping Plex Home link for #{home_user.username}: " <>
            "could not mint a per-user token (#{inspect(reason)})"
        )

        {:cont, {:ok, SeedResult.add_mint_failure(result, home_user.username)}}
    end
  end

  defp write_link(attrs, home_user, result, opts) do
    only_new = Keyword.get(opts, :only_new, false)

    case Settings.upsert_media_server_user_link(attrs, only_new: only_new) do
      {:ok, link} ->
        {:cont, {:ok, SeedResult.add_link(result, link)}}

      # A mapping the operator made by hand outranks rediscovery, and one
      # claimed profile is no reason to abandon the rest of the run.
      # `:account_already_mapped` is another Mydia user holding this profile, so
      # the profile's own name is the right thing to report.
      {:error, :account_already_mapped} ->
        {:cont, {:ok, SeedResult.add_already_mapped(result, home_user.username)}}

      # `:link_exists` is this Mydia user already holding some profile, possibly
      # a different one they picked on purpose. Only reachable as a race, since
      # `existing_link/3` catches it before the mint. Reported under the account
      # they are actually on.
      {:error, :link_exists} ->
        {:cont, {:ok, SeedResult.add_already_mapped(result, existing_label(attrs))}}

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

  `account_uuid` must be the account's `uuid`. The numeric `id` from the same
  payload answers 404 here; see `parse_user/1`.

  Returns an error rather than falling back to the admin token when a switch
  fails or returns no token: no link is better than a link pointing at someone
  else's history.
  """
  @spec token_for(map(), String.t(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def token_for(config, account_uuid, opts \\ []) do
    base = Keyword.get(opts, :plex_tv_base, @plex_api_base)

    (base <> "/home/users/#{account_uuid}/switch")
    |> Req.post(headers: headers(config), retry: false)
    |> case do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        extract_token(body, account_uuid)

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

  # `plex_account_id` carries the account's `uuid`, not its numeric `id`.
  # /home/users returns both, but the v2 switch endpoint keys on the uuid and
  # answers 404 for the numeric id, so minting a per-user token failed for every
  # profile on every install and no matched link was ever created:
  #
  #   POST /api/v2/home/users/14861644/switch         -> 404
  #   POST /api/v2/home/users/2ed8d606cadd57f0/switch -> 201 + authToken
  #
  # Nothing correlates this value with the media server's own account ids, so
  # the uuid is the only identifier that has to be right.
  #
  # `username` is null for managed and guest profiles; only `title` is set, so
  # the fallback is what names most of a household.
  defp parse_user(user) do
    %{
      plex_account_id: to_string(user["uuid"]),
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
