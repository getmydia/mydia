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
      "#{length(rows)} captures, #{plural(length(divergences), "divergence")}. " <>
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

  @max_cell 80

  defp divergences_section(divergences) do
    sorted =
      Enum.sort_by(divergences, fn d -> {d.definition, to_string(d.query), to_string(d.kind)} end)

    # Long values go whole into a details list, so the part that differs (the end
    # of a magnet link, say) is never cut off.
    {lines, details} =
      sorted
      |> Enum.with_index(1)
      |> Enum.map_reduce([], fn {d, n}, details ->
        native = inspect(d.native, limit: :infinity, printable_limit: :infinity)
        wasm = inspect(d.wasm, limit: :infinity, printable_limit: :infinity)
        long? = String.length(native) > @max_cell or String.length(wasm) > @max_cell

        {native_cell, wasm_cell, details} =
          if long? do
            {"see #{n}", "see #{n}", [{n, d, native, wasm} | details]}
          else
            {cell(native), cell(wasm), details}
          end

        {"| #{d.definition} | #{d.query} | #{d.kind} | #{d.field || ""} | #{native_cell} | #{wasm_cell} |",
         details}
      end)

    Enum.join(
      [
        "## Divergences\n",
        "| definition | query | kind | field | native | wasm |",
        "|---|---|---|---|---|---|"
        | lines
      ],
      "\n"
    ) <> "\n" <> details_section(Enum.reverse(details))
  end

  defp details_section([]), do: ""

  defp details_section(details) do
    items =
      Enum.map_join(details, "\n", fn {n, d, native, wasm} ->
        "#{n}. #{d.definition}/#{d.query} #{d.kind} #{d.field}\n" <>
          "   - native: `#{native}`\n   - wasm: `#{wasm}`"
      end)

    "\n## Long values\n\n" <> items <> "\n"
  end

  defp plural(1, word), do: "1 #{word}"
  defp plural(n, word), do: "#{n} #{word}s"

  defp fidelity(rows) do
    ratio(Enum.sum_by(rows, & &1.agreeing), Enum.sum_by(rows, & &1.paired))
  end

  defp ratio(_agreeing, 0), do: "n/a"
  defp ratio(agreeing, paired), do: :erlang.float_to_binary(agreeing / paired, decimals: 2)

  defp cell(text), do: text |> String.replace("|", "\\|") |> String.replace("\n", " ")
end
