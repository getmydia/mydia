defmodule Mydia.Config.Env.CardigannEnv do
  @moduledoc """
  Reads the `cardigann` section of `Mydia.Config.Schema` from the environment
  (`CARDIGANN_ENGINE`).
  """

  @env_var "CARDIGANN_ENGINE"

  @spec load() :: map()
  def load do
    case System.get_env(@env_var) do
      value when value in [nil, ""] -> %{}
      value -> %{engine: parse_engine(value)}
    end
  end

  # A dedicated fixed-enum parser (never String.to_atom/1 on input). An unknown
  # value becomes :invalid so validation rejects it by name instead of the
  # setting silently falling back to :builtin.
  defp parse_engine(value) do
    case value |> String.trim() |> String.downcase() do
      "builtin" -> :builtin
      "prowlarr" -> :prowlarr
      _unrecognised -> :invalid
    end
  end
end
