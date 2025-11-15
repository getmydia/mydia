defmodule Mydia.Downloads.Structs.TorrentMatchResult do
  @moduledoc """
  Represents the result of matching a torrent to a library item.

  This struct provides compile-time safety for torrent matching results,
  containing the matched media item, optional episode, confidence score,
  and explanation of why the match was made.

  Note: This is different from Mydia.Media.Structs.MatchResult which is
  used for file-to-metadata matching.

  ## Fields

  - `:media_item` - The matched MediaItem (required)
  - `:episode` - The matched Episode for TV shows (nil for movies)
  - `:confidence` - Match confidence score from 0.0 to 1.0 (required)
  - `:match_reason` - Human-readable explanation of why the match was made (required)
  """

  alias Mydia.Media.{Episode, MediaItem}

  @enforce_keys [:media_item, :confidence, :match_reason]
  defstruct [:media_item, :episode, :confidence, :match_reason]

  @type t :: %__MODULE__{
          media_item: MediaItem.t(),
          episode: Episode.t() | nil,
          confidence: float(),
          match_reason: String.t()
        }

  @doc """
  Creates a new TorrentMatchResult struct.

  ## Examples

      iex> new(media_item: %MediaItem{}, confidence: 0.95, match_reason: "TMDB ID match")
      %TorrentMatchResult{media_item: %MediaItem{}, episode: nil, confidence: 0.95, ...}

      iex> new(media_item: %MediaItem{}, episode: %Episode{}, confidence: 0.98, match_reason: "ID match with episode")
      %TorrentMatchResult{media_item: %MediaItem{}, episode: %Episode{}, ...}
  """
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    struct!(__MODULE__, attrs)
  end
end
