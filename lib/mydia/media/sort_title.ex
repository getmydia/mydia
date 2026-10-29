defmodule Mydia.Media.SortTitle do
  @moduledoc """
  The key titles sort by.

  `fold/1` accent-folds and lowercases a title. `key/1` also drops one leading
  English article ("the", "a", "an"), so "The Saltmarsh Years" sorts and files
  under S, as other media servers do. Only the sort changes; the title shown
  is always the stored one.
  """

  # Latin letters NFD leaves whole, so stripping marks cannot reach their base
  # letter. Without these, "Ørsted" would file under # rather than O.
  @latin_folds %{
    "ø" => "o",
    "æ" => "ae",
    "œ" => "oe",
    "ß" => "ss",
    "ł" => "l",
    "đ" => "d",
    "þ" => "th",
    "ð" => "d"
  }
  @latin_fold_keys Map.keys(@latin_folds)

  @article ~r/\A(?:the|a|an)\s+/

  @doc "The title accent-folded and lowercased. `nil` folds to `\"\"`."
  @spec fold(String.t() | nil) :: String.t()
  def fold(title) do
    title = title || ""

    # Invalid UTF-8 has no NFD form, and the Unicode regex would raise on it.
    # Its raw bytes still sort, and still file under some letter or #.
    case :unicode.characters_to_nfd_binary(title) do
      nfd when is_binary(nfd) ->
        nfd
        |> String.replace(~r/\p{Mn}/u, "")
        |> String.downcase()
        |> String.replace(@latin_fold_keys, &Map.fetch!(@latin_folds, &1))

      _error ->
        String.downcase(title)
    end
  end

  @doc """
  The sort key: `fold/1` without one leading "the", "a" or "an". A title that
  is nothing but an article keeps it, so it still sorts somewhere sensible.
  """
  @spec key(String.t() | nil) :: String.t()
  def key(title) do
    folded = fold(title)
    stripped = String.replace(folded, @article, "", global: false)

    if String.trim(stripped) == "", do: folded, else: stripped
  end
end
