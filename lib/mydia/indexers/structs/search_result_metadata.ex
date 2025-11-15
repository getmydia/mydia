defmodule Mydia.Indexers.Structs.SearchResultMetadata do
  @moduledoc """
  Additional metadata for search results.

  This struct contains optional metadata that may be present in search results,
  particularly for season pack downloads.

  ## Fields

  - `:season_pack` - Whether this is a season pack download (default: false)
  - `:season_number` - Season number for season packs (optional)
  - `:episode_count` - Number of episodes in the season pack (optional)
  - `:episode_ids` - List of episode IDs included in the season pack (optional)
  """

  @enforce_keys []
  defstruct [
    :season_pack,
    :season_number,
    :episode_count,
    :episode_ids
  ]

  @type t :: %__MODULE__{
          season_pack: boolean() | nil,
          season_number: integer() | nil,
          episode_count: integer() | nil,
          episode_ids: [integer()] | nil
        }

  @doc """
  Creates a new SearchResultMetadata struct.

  ## Examples

      iex> new(season_pack: true, season_number: 1, episode_count: 10)
      %SearchResultMetadata{season_pack: true, season_number: 1, episode_count: 10}

      iex> new()
      %SearchResultMetadata{}
  """
  def new(attrs \\ []) when is_list(attrs) or is_map(attrs) do
    struct!(__MODULE__, attrs)
  end

  @doc """
  Creates metadata for a season pack.

  ## Examples

      iex> season_pack(1, 10, [1, 2, 3])
      %SearchResultMetadata{season_pack: true, season_number: 1, episode_count: 10, episode_ids: [1, 2, 3]}
  """
  def season_pack(season_number, episode_count, episode_ids \\ []) do
    %__MODULE__{
      season_pack: true,
      season_number: season_number,
      episode_count: episode_count,
      episode_ids: episode_ids
    }
  end

  @doc """
  Returns true if this metadata represents a season pack.

  ## Examples

      iex> metadata = season_pack(1, 10)
      iex> season_pack?(metadata)
      true

      iex> metadata = new()
      iex> season_pack?(metadata)
      false
  """
  def season_pack?(%__MODULE__{season_pack: true}), do: true
  def season_pack?(_), do: false
end
