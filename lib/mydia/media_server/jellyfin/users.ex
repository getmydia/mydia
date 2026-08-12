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
  alias Mydia.Settings
  alias Mydia.Settings.MediaServerUserLink

  @doc """
  Fetches the server's accounts and links each match to its Mydia user.
  """
  @spec seed_links(map()) :: {:ok, [MediaServerUserLink.t()]} | {:error, term()}
  def seed_links(config) do
    with {:ok, remote_users} <- JellyfinClient.list_users(config) do
      seed_matched_links(config, remote_users)
    end
  end

  defp seed_matched_links(config, remote_users) do
    by_username =
      Map.new(Accounts.list_users(), fn user -> {String.downcase(user.username), user} end)

    remote_users
    |> Enum.reduce_while({:ok, []}, fn remote_user, {:ok, acc} ->
      name = remote_user.name || ""

      case Map.get(by_username, String.downcase(name)) do
        nil ->
          {:cont, {:ok, acc}}

        user ->
          attrs = %{
            media_server_config_id: config.id,
            user_id: user.id,
            remote_user_id: remote_user.id,
            remote_username: remote_user.name,
            enabled: true
          }

          case Settings.upsert_media_server_user_link(attrs) do
            {:ok, link} -> {:cont, {:ok, [link | acc]}}
            {:error, _reason} = error -> {:halt, error}
          end
      end
    end)
    |> case do
      {:ok, links} -> {:ok, Enum.reverse(links)}
      other -> other
    end
  end
end
