defmodule Mydia.Indexers.CardigannSummaryTest do
  # Mutates the :features config and the active-engine persistent term.
  use Mydia.DataCase, async: false

  import Mydia.IndexersFixtures

  alias Mydia.Indexers.CardigannDefinition
  alias Mydia.Indexers.CardigannSummary
  alias Mydia.Repo

  @active_key {Mydia.Indexers.Cardigann.EngineSwitcher, :active}

  setup do
    features = Application.get_env(:mydia, :features, [])
    active = :persistent_term.get(@active_key, nil)

    put_cardigann_enabled(true)

    on_exit(fn ->
      Application.put_env(:mydia, :features, features)

      if active,
        do: :persistent_term.put(@active_key, active),
        else: :persistent_term.erase(@active_key)
    end)

    :ok
  end

  defp put_cardigann_enabled(value) do
    features = Application.get_env(:mydia, :features, [])
    Application.put_env(:mydia, :features, Keyword.put(features, :cardigann_enabled, value))
  end

  defp with_health(definition, status) do
    definition
    |> CardigannDefinition.health_check_changeset(%{health_status: status})
    |> Repo.update!()
  end

  describe "build/0" do
    test "counts library trackers and enabled ones, ignoring the rest of the catalog" do
      :persistent_term.put(@active_key, :builtin)
      cardigann_definition_fixture(%{enabled: true})
      cardigann_definition_fixture(%{enabled: true})
      cardigann_definition_fixture(%{in_library: true, enabled: false})
      cardigann_definition_fixture(%{in_library: false, enabled: false})

      assert %CardigannSummary{engine: :builtin, enabled: 2, installed: 3} =
               CardigannSummary.build()
    end

    test "reports zero counts with an empty library" do
      :persistent_term.put(@active_key, :builtin)

      assert %CardigannSummary{enabled: 0, installed: 0} = CardigannSummary.build()
    end

    test "reports the engine serving searches" do
      :persistent_term.put(@active_key, :prowlarr)

      assert %CardigannSummary{engine: :prowlarr} = CardigannSummary.build()
    end

    test "is nil when the Cardigann feature is off" do
      put_cardigann_enabled(false)
      cardigann_definition_fixture(%{enabled: true})

      assert CardigannSummary.build() == nil
    end
  end

  describe "status_map/0" do
    test "maps health_status of enabled trackers to rollup statuses" do
      healthy = cardigann_definition_fixture(%{enabled: true}) |> with_health("healthy")
      degraded = cardigann_definition_fixture(%{enabled: true}) |> with_health("degraded")
      unhealthy = cardigann_definition_fixture(%{enabled: true}) |> with_health("unhealthy")
      login = cardigann_definition_fixture(%{enabled: true}) |> with_health("needs_login")
      unknown = cardigann_definition_fixture(%{enabled: true})

      assert CardigannSummary.status_map() == %{
               "cardigann:#{healthy.id}" => %{status: :healthy},
               "cardigann:#{degraded.id}" => %{status: :healthy},
               "cardigann:#{unhealthy.id}" => %{status: :unhealthy},
               "cardigann:#{login.id}" => %{status: :unhealthy},
               "cardigann:#{unknown.id}" => %{status: :unknown}
             }
    end

    test "skips trackers that are installed but disabled" do
      cardigann_definition_fixture(%{in_library: true, enabled: false}) |> with_health("healthy")

      assert CardigannSummary.status_map() == %{}
    end

    test "is empty when the Cardigann feature is off" do
      put_cardigann_enabled(false)
      cardigann_definition_fixture(%{enabled: true}) |> with_health("healthy")

      assert CardigannSummary.status_map() == %{}
    end
  end

  describe "labels" do
    test "engine_label/1" do
      assert CardigannSummary.engine_label(:builtin) == "Built-in"
      assert CardigannSummary.engine_label(:prowlarr) == "Prowlarr-based"
    end

    test "label/1" do
      summary = %CardigannSummary{engine: :builtin, enabled: 7, installed: 10}

      assert CardigannSummary.label(summary) == "Cardigann: Built-in · 7/10"
    end
  end
end
