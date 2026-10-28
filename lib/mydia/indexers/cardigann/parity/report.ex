defmodule Mydia.Indexers.Cardigann.Parity.Report do
  @moduledoc """
  Markdown report for a parity run: overall and per-definition fidelity
  (agreeing results over paired results), then a table of divergences.
  """

  alias Mydia.Indexers.Cardigann.Parity.Divergence

  @type row :: %{
          definition: String.t(),
          query: atom(),
          divergences: [Divergence.t()],
          paired: non_neg_integer(),
          agreeing: non_neg_integer()
        }

  @spec render([row()]) :: String.t()
  def render(rows) do
    divergences = Enum.flat_map(rows, & &1.divergences)

    [
      "# Cardigann parity report\n",
      "#{length(rows)} captures, #{length(divergences)} divergences. " <>
        "Overall fidelity: #{fidelity(rows)}.\n",
      definitions_section(rows),
      divergences_section(divergences)
    ]
    |> Enum.join("\n")
  end

  defp definitions_section(rows) do
    lines =
      rows
      |> Enum.group_by(& &1.definition)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {definition, group} ->
        paired = Enum.sum_by(group, & &1.paired)
        agreeing = Enum.sum_by(group, & &1.agreeing)
        divs = Enum.sum_by(group, &length(&1.divergences))
        "| #{definition} | #{paired} | #{agreeing} | #{ratio(agreeing, paired)} | #{divs} |"
      end)

    Enum.join(
      [
        "## Fidelity per definition\n",
        "| definition | paired | agreeing | fidelity | divergences |",
        "|---|---:|---:|---:|---:|"
        | lines
      ],
      "\n"
    ) <> "\n"
  end

  defp divergences_section([]), do: "## Divergences\n\nNone.\n"

  defp divergences_section(divergences) do
    lines =
      divergences
      |> Enum.sort_by(fn d -> {d.definition, to_string(d.query), to_string(d.kind)} end)
      |> Enum.map(fn d ->
        "| #{d.definition} | #{d.query} | #{d.kind} | #{d.field || ""} | " <>
          "#{cell(d.native)} | #{cell(d.wasm)} |"
      end)

    Enum.join(
      [
        "## Divergences\n",
        "| definition | query | kind | field | native | wasm |",
        "|---|---|---|---|---|---|"
        | lines
      ],
      "\n"
    ) <> "\n"
  end

  defp fidelity(rows) do
    ratio(Enum.sum_by(rows, & &1.agreeing), Enum.sum_by(rows, & &1.paired))
  end

  defp ratio(_agreeing, 0), do: "n/a"
  defp ratio(agreeing, paired), do: :erlang.float_to_binary(agreeing / paired, decimals: 2)

  # Table cells: one short line, with pipes escaped.
  defp cell(value) do
    value
    |> inspect(limit: 5, printable_limit: 80)
    |> String.slice(0, 120)
    |> String.replace("|", "\\|")
    |> String.replace("\n", " ")
  end
end
