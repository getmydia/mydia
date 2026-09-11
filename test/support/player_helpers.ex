defmodule Mydia.PlayerHelpers do
  @moduledoc """
  Turns the player off for one test.

  `Mydia.Player.enabled?/0` reads application env, which the Ecto sandbox does
  not roll back, so every test using this must be `async: false`.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc "Makes `Mydia.Player.enabled?/0` return false until the test exits."
  @spec disable_player() :: :ok
  def disable_player do
    previous = Application.fetch_env(:mydia, :player_enabled)
    Application.put_env(:mydia, :player_enabled, false)
    on_exit(fn -> restore(previous) end)
    :ok
  end

  defp restore({:ok, value}), do: Application.put_env(:mydia, :player_enabled, value)
  defp restore(:error), do: Application.delete_env(:mydia, :player_enabled)
end
