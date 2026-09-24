defmodule Mydia.Accounts.PosterFields do
  @moduledoc """
  The pieces of a library poster card a user can turn on or off.

  Stored per user as a list of key strings under `"poster_fields"` in
  `Mydia.Accounts.UserPreference`, the same shape as `HomeLayout`'s
  `"home_widgets"`. Nothing is stored until the user changes something, so a
  missing key resolves to `default_keys/0`, which is exactly the card as it
  rendered before this preference existed. The two badges added for issue #917
  start off because posters were already crowded.

  Order is the catalog's, not the stored list's: the card has fixed slots, so
  there is nothing to reorder.
  """

  @catalog [
    {:playback, "Watched"},
    {:quality, "Quality"},
    {:status, "Status"},
    {:category, "Category"},
    {:year, "Year"},
    {:episodes, "Episodes"},
    {:content_rating, "Age rating"},
    {:show_status, "Show status"}
  ]

  @default_keys [:playback, :quality, :status, :category, :year, :episodes]
  @keys Enum.map(@catalog, &elem(&1, 0))
  @by_string Map.new(@keys, &{Atom.to_string(&1), &1})

  @spec catalog() :: [{atom(), String.t()}]
  def catalog, do: @catalog

  @spec valid_key_strings() :: [String.t()]
  def valid_key_strings, do: Map.keys(@by_string)

  @spec default_keys() :: [atom()]
  def default_keys, do: @default_keys

  @doc """
  Resolves a stored value to the enabled keys in catalog order. nil or a
  non-list means never set and gives the defaults; `[]` means everything off.
  """
  @spec resolve(term()) :: [atom()]
  def resolve(stored) when is_list(stored) do
    enabled = stored |> Enum.map(&to_key/1) |> MapSet.new()
    Enum.filter(@keys, &MapSet.member?(enabled, &1))
  end

  def resolve(_stored), do: @default_keys

  @spec show?([atom()], atom()) :: boolean()
  def show?(fields, key), do: key in fields

  defp to_key(key) when is_atom(key) and key in @keys, do: key
  defp to_key(key) when is_binary(key), do: Map.get(@by_string, key)
  defp to_key(_key), do: nil
end
