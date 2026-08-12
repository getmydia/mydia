defmodule Mydia.MediaServer.Plex.Selection do
  @moduledoc """
  Decides which Plex server to attach, and turns that choice into config attrs.

  This is policy, kept out of `PlexOAuth` (which is transport) and out of the
  LiveView (which cannot be exercised without a socket). A Plex account often
  carries several servers: the operator's own, plus any shared by friends. The
  rule is to pick silently whenever the choice is not a real choice, and to ask
  only when it genuinely is.
  """

  alias Mydia.MediaServer.PlexOAuth

  @type server :: PlexOAuth.server()

  @doc """
  Picks the server to attach.

  `PlexOAuth.list_servers/2` has already filtered to resources that provide
  `server`, so no capability filtering happens here.
  """
  @spec auto_select([server()]) ::
          {:ok, server()} | {:ambiguous, [server()]} | {:error, :no_servers}
  def auto_select([]), do: {:error, :no_servers}
  def auto_select([single]), do: {:ok, single}

  def auto_select(servers) when is_list(servers) do
    case Enum.filter(servers, & &1.owned) do
      [single] -> {:ok, single}
      _ -> {:ambiguous, rank(servers)}
    end
  end

  @doc """
  Orders servers owned-first, then online, then by name.

  Only matters for the picker that renders when the choice is ambiguous, but a
  ranked list makes that picker coherent instead of arbitrary.
  """
  @spec rank([server()]) :: [server()]
  def rank(servers) when is_list(servers) do
    # `not owned` sorts false before true, so owned servers come first.
    Enum.sort_by(servers, fn s -> {not s.owned, not s.presence, s.name || ""} end)
  end

  @doc """
  Builds `MediaServerConfig` attrs for a chosen server.

  `url` stays nil deliberately: a non-nil `url` is a manual operator override
  that bypasses discovery entirely, and this path is discovery.

  `now` is an argument rather than a `DateTime.utc_now/0` call in the body so
  the function stays testable without mocking the clock.
  """
  @spec config_attrs(server(), String.t(), DateTime.t()) :: map()
  def config_attrs(server, account_token, now \\ DateTime.utc_now()) do
    %{
      name: server.name,
      type: :plex,
      url: nil,
      token: account_token,
      machine_identifier: server.machine_identifier,
      connections: server.connections,
      server_access_token: server.access_token,
      connections_refreshed_at: DateTime.truncate(now, :second),
      enabled: true
    }
  end
end
