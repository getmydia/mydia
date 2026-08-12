defmodule Mydia.Indexers.Cardigann.FeaturesFixtureGuardTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.Features

  @fixtures_base "test/fixtures/cardigann"

  # A feature may only be declared supported when at least one captured fixture
  # exercises it. Without this, `Features.supported/0` is a wish list and
  # `mix mydia.cardigann_compat` reports numbers nobody verified. This is the
  # same failure mode as the old filter-only report.
  test "every supported feature is exercised by at least one fixture" do
    covered =
      @fixtures_base
      |> File.ls!()
      |> Enum.map(&Path.join(@fixtures_base, &1))
      |> Enum.filter(&File.dir?/1)
      |> Enum.flat_map(fn dir ->
        case File.read(Path.join(dir, "definition.yml")) do
          {:ok, yaml} ->
            case YamlElixir.read_from_string(yaml) do
              {:ok, map} -> MapSet.to_list(Features.required(map))
              _ -> []
            end

          _ ->
            []
        end
      end)
      |> MapSet.new()

    uncovered = Features.supported() |> MapSet.new() |> MapSet.difference(covered)

    assert MapSet.size(uncovered) == 0,
           "features declared supported but exercised by no fixture: #{inspect(MapSet.to_list(uncovered))}"
  end
end
