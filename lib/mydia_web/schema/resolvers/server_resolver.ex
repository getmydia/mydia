defmodule MydiaWeb.Schema.Resolvers.ServerResolver do
  @moduledoc """
  Resolves server-level facts a player needs before it can trust the rest of
  the API.
  """

  alias Mydia.Compatibility
  alias Mydia.System

  @doc """
  Returns this server's version and the player version floors it declares.

  Never fails: every value is a compile-time constant, a release attribute, or
  the remote access instance id (nil until remote access was first enabled).
  """
  def compatibility(_parent, _args, _resolution) do
    {:ok,
     %{
       version: System.app_version(),
       min_player_version: Compatibility.min_player_version(),
       recommended_player_version: Compatibility.recommended_player_version(),
       instance_id: instance_id()
     }}
  end

  defp instance_id do
    case Mydia.RemoteAccess.get_config() do
      %{instance_id: id} -> id
      nil -> nil
    end
  end
end
