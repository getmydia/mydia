defmodule Mydia.MediaServer.Jellyfin.Users do
  @moduledoc """
  Seeds `media_server_user_links` from a Jellyfin server's accounts.

  Each Jellyfin account is matched to a Mydia user by case-insensitive
  username. Unmatched accounts are skipped rather than guessed at, and the
  operator resolves them in the mapping UI. Guessing (linking to an admin or
  the first user) would run watched sync for that account against the wrong
  person's history, which is exactly what per-user mapping exists to prevent.

  Unlike Plex there is no per-user token to mint: Jellyfin issues no
  per-account tokens, so the link stores only the account's GUID and the
  server's own API key does the talking for every linked user.
  """

  alias Mydia.Accounts
  alias Mydia.MediaServer.Client.Jellyfin, as: JellyfinClient
  alias Mydia.MediaServer.SeedResult
  alias Mydia.Settings

  @doc """
  Fetches the server's accounts and links each match to its Mydia user.
  """
  @spec seed_links(map()) :: {:ok, SeedResult.t()} | {:error, term()}
  def seed_links(config) do
    with {:ok, remote_users} <- JellyfinClient.list_users(config) do
      seed_matched_links(config, remote_users)
    end
  end

  defp seed_matched_links(config, remote_users) do
    by_username =
      Map.new(Accounts.list_users(), fn user -> {String.downcase(user.username), user} end)

    remote_users
    |> Enum.reduce_while({:ok, %SeedResult{}}, fn remote_user, {:ok, result} ->
      name = remote_user.name || ""

      case Map.get(by_username, String.downcase(name)) do
        nil -> {:cont, {:ok, result}}
        user -> link_account(config, user, remote_user, result)
      end
    end)
    |> case do
      {:ok, result} -> {:ok, SeedResult.finish(result)}
      other -> other
    end
  end

  defp link_account(config, user, remote_user, result) do
    attrs = %{
      media_server_config_id: config.id,
      user_id: user.id,
      remote_user_id: remote_user.id,
      remote_username: remote_user.name,
      enabled: true
    }

    case Settings.upsert_media_server_user_link(attrs) do
      {:ok, link} ->
        {:cont, {:ok, SeedResult.add_link(result, link)}}

      # A mapping the operator made by hand outranks rediscovery. One account
      # already claimed is also no reason to abandon the rest of the run, which
      # is what halting here used to do.
      {:error, :account_already_mapped} ->
        {:cont, {:ok, SeedResult.add_already_mapped(result, remote_user.name)}}

      {:error, _reason} = error ->
        {:halt, error}
    end
  end
end
