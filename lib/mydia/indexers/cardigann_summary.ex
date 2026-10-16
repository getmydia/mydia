defmodule Mydia.Indexers.CardigannSummary do
  @moduledoc """
  What the home Indexers tile and the manual search summary say about Cardigann:
  the engine serving searches, and how many library trackers are enabled out of
  those installed.

  `status_map/0` feeds the same trackers into `Mydia.Health.Rollup` next to the
  configured connections, so the tile's health badge covers both.
  """

  import Ecto.Query, only: [from: 2]

  alias Mydia.Indexers.Cardigann.EngineSwitcher
  alias Mydia.Indexers.CardigannDefinition
  alias Mydia.Indexers.CardigannFeatureFlags
  alias Mydia.Repo

  @enforce_keys [:engine, :enabled, :installed]
  defstruct [:engine, :enabled, :installed]

  @type engine :: :builtin | :prowlarr
  @type t :: %__MODULE__{
          engine: engine(),
          enabled: non_neg_integer(),
          installed: non_neg_integer()
        }

  @doc """
  Builds the summary, or returns `nil` when the Cardigann feature is off.

  `engine` is the engine serving searches now, so during a switch it names the
  old engine until the new one is ready.
  """
  @spec build() :: t() | nil
  def build do
    if CardigannFeatureFlags.enabled?() do
      counts =
        from(d in CardigannDefinition,
          where: d.in_library == true,
          group_by: d.enabled,
          select: {d.enabled, count(d.id)}
        )
        |> Repo.all()
        |> Map.new()

      enabled = Map.get(counts, true, 0)

      %__MODULE__{
        engine: EngineSwitcher.active(),
        enabled: enabled,
        installed: enabled + Map.get(counts, false, 0)
      }
    end
  end

  @doc """
  Health of the enabled library trackers, keyed `"cardigann:<id>"` so the map
  can merge with `Mydia.Indexers.Health.status_map/0` without id collisions.

  A degraded tracker answered, just slowly, so it counts as healthy. A tracker
  that needs a fresh login cannot search, so it counts as unhealthy.
  """
  @spec status_map() :: %{String.t() => %{status: :healthy | :unhealthy | :unknown}}
  def status_map do
    if CardigannFeatureFlags.enabled?() do
      from(d in CardigannDefinition,
        where: d.enabled == true,
        select: {d.id, d.health_status}
      )
      |> Repo.all()
      |> Map.new(fn {id, health} -> {"cardigann:#{id}", %{status: rollup_status(health)}} end)
    else
      %{}
    end
  end

  @spec engine_label(engine()) :: String.t()
  def engine_label(:builtin), do: "Built-in"
  def engine_label(:prowlarr), do: "Prowlarr-based"

  @spec label(t()) :: String.t()
  def label(%__MODULE__{engine: engine, enabled: enabled, installed: installed}),
    do: "Cardigann: #{engine_label(engine)} · #{enabled}/#{installed}"

  defp rollup_status(health) when health in ["healthy", "degraded"], do: :healthy
  defp rollup_status(health) when health in ["unhealthy", "needs_login"], do: :unhealthy
  defp rollup_status(_health), do: :unknown
end
