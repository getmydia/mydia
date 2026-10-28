defmodule Mydia.Indexers.Cardigann.Parity.ReportTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.Parity.{Divergence, Report}

  defp row(definition, query, divergences, paired, agreeing),
    do: %{
      definition: definition,
      query: query,
      divergences: divergences,
      paired: paired,
      agreeing: agreeing
    }

  test "summarises fidelity overall and per definition, and lists divergences" do
    div = %Divergence{
      definition: "harbor",
      query: :generic,
      kind: :field,
      field: :seeders,
      native: 4,
      wasm: "a|b"
    }

    md =
      Report.render([
        row("harbor", :generic, [div], 4, 3),
        row("harbor", :rss, [], 4, 4),
        row("orchard", :generic, [], 2, 2)
      ])

    assert md =~ "3 captures, 1 divergences. Overall fidelity: 0.90."
    assert md =~ "| harbor | 8 | 7 | 0.88 | 1 |"
    assert md =~ "| orchard | 2 | 2 | 1.00 | 0 |"
    assert md =~ "| harbor | generic | field | seeders | 4 | \"a\\|b\" |"
  end

  test "an empty divergence list and nothing paired render without dividing by zero" do
    md = Report.render([row("harbor", :rss, [], 0, 0)])
    assert md =~ "Overall fidelity: n/a"
    assert md =~ "None."
  end
end
