defmodule Mydia.Compatibility do
  @moduledoc """
  Version floors this server declares to connecting players.

  Mydia servers and players ship from the same release tag but operators
  upgrade on their own timeline, so both sides can be on different releases at
  once. These constants let a server tell a player that it is too old to work
  correctly, instead of the mismatch surfacing as an unexplained failure.

  ## When to bump

  Bump `@min_player_version` to the release you are shipping when that release
  makes a change a older player cannot cope with: removing or renaming a
  GraphQL field the player selects, changing the meaning of a response, or
  changing a streaming or download contract.

  Bump `@recommended_player_version` when a release adds something a player
  needs to take advantage of, but whose absence degrades gracefully.

  Do not bump either for routine releases. Every bump nags every operator
  running an older player, and a floor that moves on every release trains
  people to ignore the banner.

  The player carries the mirror of these values, the oldest server it works
  with, in `player/lib/core/compatibility/compatibility.dart`. The two are
  different facts and neither derives from the other.

  ## Last changed

  - 0.9.0: initial baseline, set to the release this mechanism shipped in.
  """

  @min_player_version "0.9.0"
  @recommended_player_version "0.9.0"

  @doc "The oldest player version this server works with."
  @spec min_player_version() :: String.t()
  def min_player_version, do: @min_player_version

  @doc "The oldest player version this server would rather you were running."
  @spec recommended_player_version() :: String.t()
  def recommended_player_version, do: @recommended_player_version
end
