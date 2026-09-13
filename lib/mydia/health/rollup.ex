defmodule Mydia.Health.Rollup do
  @moduledoc """
  Calculates aggregate health state from service status maps.
  """

  @enforce_keys [:healthy, :unhealthy, :unknown, :total, :state]
  defstruct [:healthy, :unhealthy, :unknown, :total, :state]

  @type state :: :none | :checking | :down | :degraded | :ok

  @type t :: %__MODULE__{
          healthy: non_neg_integer(),
          unhealthy: non_neg_integer(),
          unknown: non_neg_integer(),
          total: non_neg_integer(),
          state: state()
        }

  @doc """
  Builds a `%Rollup{}` from a status map of `id => health_result`.
  Disabled entries are excluded from all counts.
  """
  @spec from_status_map(map()) :: t()
  def from_status_map(status_map) when is_map(status_map) do
    statuses =
      status_map
      |> Map.values()
      |> Enum.map(fn
        %{status: status} -> status
        status when is_atom(status) -> status
      end)
      |> Enum.reject(&(&1 == :disabled))

    healthy = Enum.count(statuses, &(&1 == :healthy))
    unhealthy = Enum.count(statuses, &(&1 == :unhealthy))
    unknown = Enum.count(statuses, &(&1 == :unknown))
    total = length(statuses)

    state =
      cond do
        total == 0 -> :none
        unknown == total -> :checking
        unhealthy == total -> :down
        unhealthy > 0 -> :degraded
        true -> :ok
      end

    %__MODULE__{
      healthy: healthy,
      unhealthy: unhealthy,
      unknown: unknown,
      total: total,
      state: state
    }
  end

  @doc "Formats the rollup into display text."
  @spec label(t()) :: String.t()
  def label(%__MODULE__{state: :none}), do: ""
  def label(%__MODULE__{state: :checking}), do: "Checking…"

  def label(%__MODULE__{healthy: h, total: t, unknown: u}) when u > 0 do
    "#{h}/#{t} healthy, #{u} checking"
  end

  def label(%__MODULE__{healthy: h, total: t}) do
    "#{h}/#{t} healthy"
  end
end
