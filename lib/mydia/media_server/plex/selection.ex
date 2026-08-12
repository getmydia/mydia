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

  @doc """
  Re-applies discovery-owned attrs onto form params.

  The wizard's discovered fields are deliberately absent from the modal's form:
  `connections` is a list rather than an input, the two tokens are secrets that
  should not be rendered into the page, and none of them are operator-editable.
  Without this merge the LiveView's change and submit handlers rebuild the
  changeset from browser params alone and silently drop every one of them,
  leaving a config with no `url` and no discovery data, which
  `MediaServerConfig.changeset/2` then rejects.

  `params` arrive string-keyed from the browser and `cast/3` rejects a map that
  mixes atom and string keys, so the atom keys from `config_attrs/3` are
  converted here. The `connections` value itself stays as-is: `JsonListType`
  passes lists through untouched and Jason stringifies their keys on dump.
  """
  @spec merge_discovery(map(), map() | nil) :: map()
  def merge_discovery(params, nil), do: params

  def merge_discovery(%{"type" => "plex"} = params, discovery) when is_map(discovery) do
    Map.merge(params, %{
      "machine_identifier" => discovery[:machine_identifier],
      "connections" => discovery[:connections],
      "server_access_token" => discovery[:server_access_token],
      "connections_refreshed_at" => discovery[:connections_refreshed_at],
      "token" => discovery[:token]
    })
  end

  # Any other type means the operator moved the Type select off Plex. Discovery
  # no longer describes what is being saved, so it is dropped rather than
  # smuggled into a Jellyfin config.
  def merge_discovery(params, _discovery), do: params
end
