defmodule Mydia.LibrarySearch.Tokenizer do
  @moduledoc """
  Normalizes a raw library-search query into database-safe tokens.

  Normalization happens entirely in Elixir, before any query is built:

  1. Downcase and trim.
  2. Split on whitespace.
  3. Discard empty tokens.
  4. Cap at #{8} tokens to bound query size.
  5. Escape `%`, `_` and `\\` so a user query cannot inject `LIKE` wildcards.

  Step 5 is not optional. Without it a query containing `%` matches the entire
  library. Every `LIKE` built from these patterns must carry an explicit
  `ESCAPE '\\'` clause; both SQLite and PostgreSQL implement it identically.
  """

  @max_tokens 8

  @enforce_keys [:query, :tokens]
  defstruct [:query, :tokens]

  @type t :: %__MODULE__{query: String.t(), tokens: [String.t()]}

  @doc """
  Normalizes `query` into a `%Tokenizer{}`, or returns `:empty` when the query
  contains no usable tokens.

  `:query` is the whitespace-collapsed, downcased form used for ranking.
  `:tokens` are the individual terms, each of which contributes one `LIKE`
  predicate, `AND`-ed with the others.
  """
  @spec normalize(term()) :: {:ok, t()} | :empty
  def normalize(query) when is_binary(query) do
    tokens =
      query
      |> String.downcase()
      |> String.split(~r/\s+/, trim: true)
      |> Enum.take(@max_tokens)

    case tokens do
      [] -> :empty
      tokens -> {:ok, %__MODULE__{query: Enum.join(tokens, " "), tokens: tokens}}
    end
  end

  def normalize(_query), do: :empty

  @doc """
  Escapes `LIKE` metacharacters using `\\` as the escape character.

  The escape character is replaced first, otherwise the backslashes introduced
  by the wildcard replacements would themselves be escaped.
  """
  @spec escape_like(String.t()) :: String.t()
  def escape_like(term) when is_binary(term) do
    term
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  @doc "Pattern matching `term` anywhere in the column."
  @spec contains_pattern(String.t()) :: String.t()
  def contains_pattern(term), do: "%" <> escape_like(term) <> "%"

  @doc "Pattern matching `term` at the start of the column (rank tier 75)."
  @spec prefix_pattern(String.t()) :: String.t()
  def prefix_pattern(term), do: escape_like(term) <> "%"

  @doc "Pattern matching `term` at a word boundary inside the column (rank tier 50)."
  @spec word_pattern(String.t()) :: String.t()
  def word_pattern(term), do: "% " <> escape_like(term) <> "%"
end
