defmodule MydiaWeb.Schema.Resolvers.ServerResolver do
  @moduledoc """
  Resolves server-level facts a player needs before it can trust the rest of
  the API.
  """

  alias Mydia.Compatibility
  alias Mydia.System

  @doc """
  Returns this server's version and the player version floors it declares.

  Never fails: every value is a compile-time constant or a release attribute.
  """
  def compatibility(_parent, _args, _resolution) do
    {:ok,
     %{
       version: System.app_version(),
       min_player_version: Compatibility.min_player_version(),
       recommended_player_version: Compatibility.recommended_player_version()
     }}
  end
end
