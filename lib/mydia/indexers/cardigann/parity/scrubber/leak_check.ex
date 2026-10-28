defmodule Mydia.Indexers.Cardigann.Parity.Scrubber.LeakCheck do
  @moduledoc """
  Looks for real work names in scrubbed text without reusing the renamer's
  list of forms, so a form the renamer never thought of still gets caught.

  Text and work are both reduced to lowercase letters and digits after undoing
  every encoding a tracker plausibly applies: percent-encoding (up to three
  times, for `%2520`), the definition's charset, JSON string escapes and HTML
  entities (every named one lexbor knows, decimal and hex). "Kiln's Harbor"
  becomes `kilnsharbor`, and so do `Kiln&#039;s Harbor`, `kilns-harbor` and
  `Kiln%2527s%2520Harbor`. The cost is false alarms where a short work runs
  across a word boundary; those fail the seed, which is the safe direction.
  """

  alias Mydia.Indexers.Cardigann.Charset

  @percent ~r/%([0-9A-Fa-f]{2})/
  @json_escape ~r/\\u([0-9A-Fa-f]{4})(?:\\u([0-9A-Fa-f]{4}))?/
  @entity ~r/&(#[0-9]+|#[xX][0-9A-Fa-f]+|[A-Za-z][A-Za-z0-9]*);/
  @not_alnum ~r/[^\p{L}\p{N}]+/u

  @doc "`text` (raw bytes in `encoding`) reduced for searching."
  @spec normalise(binary(), String.t() | nil) :: String.t()
  def normalise(text, encoding) do
    text
    |> percent_decode(3)
    |> Charset.decode(encoding)
    |> String.replace_invalid()
    |> json_unescape()
    |> entity_decode()
    |> entity_decode()
    |> reduce()
  end

  @doc "A work (UTF-8) reduced the same way."
  @spec normalise_work(String.t()) :: String.t()
  def normalise_work(work), do: work |> entity_decode() |> reduce()

  defp reduce(text), do: text |> String.downcase() |> String.replace(@not_alnum, "")

  defp percent_decode(text, 0), do: text

  defp percent_decode(text, passes) do
    decoded =
      Regex.replace(@percent, text, fn _, hex -> <<String.to_integer(hex, 16)>> end)

    if decoded == text, do: text, else: percent_decode(decoded, passes - 1)
  end

  defp json_unescape(text) do
    text
    |> String.replace("\\/", "/")
    |> then(&Regex.replace(@json_escape, &1, fn _, high, low -> code_points(high, low) end))
  end

  defp code_points(high, ""), do: char(String.to_integer(high, 16))

  defp code_points(high, low) do
    {h, l} = {String.to_integer(high, 16), String.to_integer(low, 16)}

    if h in 0xD800..0xDBFF and l in 0xDC00..0xDFFF,
      do: char(0x10000 + (h - 0xD800) * 0x400 + (l - 0xDC00)),
      else: char(h) <> char(l)
  end

  defp char(cp) when cp in 0xD800..0xDFFF or cp > 0x10FFFF, do: ""
  defp char(cp), do: <<cp::utf8>>

  defp entity_decode(text) do
    # One lexbor call per distinct named entity, not per occurrence.
    named =
      for [whole, "" <> ref] <- Regex.scan(@entity, text),
          not String.starts_with?(ref, "#"),
          into: %{},
          do: {whole, named(whole)}

    Regex.replace(@entity, text, fn whole, ref ->
      case ref do
        "#x" <> hex -> hex |> String.to_integer(16) |> char()
        "#X" <> hex -> hex |> String.to_integer(16) |> char()
        "#" <> dec -> dec |> String.to_integer() |> char()
        _named -> Map.fetch!(named, whole)
      end
    end)
  end

  # lexbor carries the full HTML5 entity table; asking it is cheaper and more
  # complete than keeping a copy here.
  defp named(entity), do: entity |> LazyHTML.from_fragment() |> LazyHTML.text()
end
