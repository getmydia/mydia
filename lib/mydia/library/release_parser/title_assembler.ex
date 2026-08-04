defmodule Mydia.Library.ReleaseParser.TitleAssembler do
  @moduledoc """
  Reconstructs a human-readable title from the leftover title-zone
  tokens.

  The resolver has already marked which tokens belong to the title
  (everything classified as `:title_candidate` whose byte offset sits
  before the title boundary). This module just stitches them back into
  a single string, normalizes whitespace, and applies smart
  capitalization.

  ## Smart capitalization

  - Tokens that already contain at least one uppercase letter are kept
    as-is. This preserves intentional casing such as `iPhone`, `S01E01`,
    or branded `WALL-E` style titles.
  - Tokens that are entirely lowercase or entirely digits are
    title-cased: first byte uppercased, rest lowercased.
  - Tokens are joined with a single space.

  ## Parenthetical runs

  A contiguous run of tokens tokenized out of `(...)` (tracked via
  `Token.bracket_context == :paren`) is re-wrapped in parens once
  rendered, e.g. `Ghosts (US)` rather than `Ghosts Us`. This only
  applies to round parens — square-bracket runs are left bare, since
  those are overwhelmingly noise (fansub group tags, site tags, hash
  IDs; see `CORPUS_FAILURES.md`) that should not be dressed up as if it
  were meaningful title content.

  ## Byte-safety

  Per the parser-wide rule, **no `String.slice/3` and no
  `String.length/1`** anywhere in this module. We work on bytes via
  `:binary.part/3` and `binary_part/3`.
  """

  alias Mydia.Library.ReleaseParser.Token

  @doc """
  Build a title from the given tokens.

  `title_boundary` is the byte offset returned by
  `Tokenizer.title_boundary/2`. Tokens whose byte offset is greater than
  or equal to the boundary are dropped — they belong to the metadata
  zone even if a stray `:title_candidate` slipped through.

  Returns `nil` when no usable token remains. Returns a non-empty
  `String.t()` otherwise.
  """
  @spec assemble([Token.t()], non_neg_integer() | :infinity) :: String.t() | nil
  def assemble(tokens, title_boundary) when is_list(tokens) do
    tokens
    |> Enum.filter(&within_title_zone?(&1, title_boundary))
    |> Enum.chunk_by(& &1.bracket_context)
    |> Enum.map(&render_chunk/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
    |> nil_if_empty()
  end

  defp render_chunk([%Token{bracket_context: :paren} | _] = chunk) do
    case render_words(chunk) do
      "" -> ""
      words -> "(" <> words <> ")"
    end
  end

  defp render_chunk(chunk), do: render_words(chunk)

  defp render_words(chunk) do
    chunk
    |> Enum.map(& &1.value)
    |> Enum.map(&strip_outer_punct/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map_join(" ", &smart_capitalize/1)
  end

  defp within_title_zone?(%Token{byte_offset: o}, :infinity), do: o >= 0
  defp within_title_zone?(%Token{byte_offset: o}, boundary), do: o < boundary

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(s), do: s

  # Strip leading/trailing punctuation bytes (ASCII). This handles cases
  # like a leftover `-` between sub-tokens. We only touch ASCII
  # punctuation to keep multibyte titles untouched.
  defp strip_outer_punct(value) when is_binary(value) do
    value
    |> strip_leading_punct()
    |> strip_trailing_punct()
  end

  defp strip_leading_punct(<<byte, rest::binary>>) when byte in ~c"-_.,:;!?'\"" do
    strip_leading_punct(rest)
  end

  defp strip_leading_punct(other), do: other

  defp strip_trailing_punct(<<>>), do: <<>>

  defp strip_trailing_punct(bin) when is_binary(bin) do
    size = byte_size(bin)
    last = :binary.at(bin, size - 1)

    if last in ~c"-_.,:;!?'\"" do
      strip_trailing_punct(binary_part(bin, 0, size - 1))
    else
      bin
    end
  end

  # Capitalize a single token using byte slicing only.
  #
  # Semantics matching V2's `smart_capitalize/1` (lib/mydia/library/file_parser_v2.ex:1054):
  #
  # - All-uppercase ASCII (e.g. "MOVIE") → title-case ("Movie")
  # - Mixed case that's neither all-upper nor capitalized (e.g. "ThE",
  #   "MoViE") → title-case ("The", "Movie")
  # - Already capitalized ("Movie") or contains a dash ("One-Punch") → unchanged
  # - All lowercase → capitalize
  # - All-digits → unchanged
  defp smart_capitalize(""), do: ""

  defp smart_capitalize(value) do
    cond do
      all_digits?(value) -> value
      contains_dash?(value) -> value
      all_ascii_alpha?(value) and all_lower?(value) -> title_case_byte(value)
      all_ascii_alpha?(value) and all_upper?(value) -> title_case_byte(value)
      all_ascii_alpha?(value) and already_capitalized?(value) -> value
      all_ascii_alpha?(value) -> title_case_byte(value)
      true -> value
    end
  end

  defp contains_dash?(value) do
    case :binary.match(value, "-") do
      :nomatch -> false
      _ -> true
    end
  end

  defp all_ascii_alpha?(value) do
    all_alpha_bytes?(value, 0, byte_size(value))
  end

  defp all_alpha_bytes?(_value, idx, size) when idx >= size, do: true

  defp all_alpha_bytes?(value, idx, size) do
    byte = :binary.at(value, idx)

    if byte in ?A..?Z or byte in ?a..?z do
      all_alpha_bytes?(value, idx + 1, size)
    else
      false
    end
  end

  defp all_lower?(value) do
    all_lower_bytes?(value, 0, byte_size(value))
  end

  defp all_lower_bytes?(_value, idx, size) when idx >= size, do: true

  defp all_lower_bytes?(value, idx, size) do
    byte = :binary.at(value, idx)
    if byte in ?a..?z, do: all_lower_bytes?(value, idx + 1, size), else: false
  end

  defp all_upper?(value) do
    all_upper_bytes?(value, 0, byte_size(value))
  end

  defp all_upper_bytes?(_value, idx, size) when idx >= size, do: true

  defp all_upper_bytes?(value, idx, size) do
    byte = :binary.at(value, idx)
    if byte in ?A..?Z, do: all_upper_bytes?(value, idx + 1, size), else: false
  end

  defp already_capitalized?(<<first, rest::binary>>) when first in ?A..?Z do
    all_lower?(rest)
  end

  defp already_capitalized?(_), do: false

  defp all_digits?(value) do
    all_digits_bytes?(value, 0, byte_size(value))
  end

  defp all_digits_bytes?(_value, idx, size) when idx >= size, do: true

  defp all_digits_bytes?(value, idx, size) do
    byte = :binary.at(value, idx)

    if byte in ?0..?9 do
      all_digits_bytes?(value, idx + 1, size)
    else
      false
    end
  end

  # Title-case via byte slicing. Works for ASCII letters; preserves
  # multibyte leading characters (byte-level case ops would corrupt
  # them).
  defp title_case_byte(<<first, rest::binary>>) when first in ?a..?z do
    upper_first = first - 32
    <<upper_first, String.downcase(rest)::binary>>
  end

  defp title_case_byte(<<first, rest::binary>>) when first in ?A..?Z do
    <<first, String.downcase(rest)::binary>>
  end

  defp title_case_byte(value), do: value
end
