defmodule Mydia.LibrarySearch.Rank do
  @moduledoc """
  The single definition of the library-search relevance tiers.

  | Rank | Condition |
  | --- | --- |
  | 100 | `lower(title) = query` |
  | 75 | `lower(title)` starts with `query` |
  | 50 | `query` starts a word inside `lower(title)` |
  | 25 | any other substring match |

  Ecto's `fragment/1` requires a literal string, so the expression is generated
  by a macro rather than shared through a function. This keeps the tiers in one
  place across the three entity queries; duplicating the `CASE` would let the
  sections silently drift apart, which is exactly what this design must avoid.

  `lower/1` is ASCII-only on both SQLite and PostgreSQL, so non-ASCII case
  folding is imperfect. That limitation is known and accepted.
  """

  @doc """
  Builds the ranking `CASE` expression over `field`.

  `query` is the whitespace-collapsed normalized query, `prefix` is
  `Tokenizer.prefix_pattern/1` of it, and `word` is `Tokenizer.word_pattern/1`
  of it. All three must be interpolated with `^`.
  """
  defmacro rank(field, query, prefix, word) do
    quote do
      fragment(
        """
        CASE
          WHEN lower(?) = ? THEN 100
          WHEN lower(?) LIKE ? ESCAPE '\\' THEN 75
          WHEN lower(?) LIKE ? ESCAPE '\\' THEN 50
          ELSE 25
        END
        """,
        unquote(field),
        unquote(query),
        unquote(field),
        unquote(prefix),
        unquote(field),
        unquote(word)
      )
    end
  end
end
