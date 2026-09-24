defmodule Mydia.Media.ShowStatus do
  @moduledoc """
  A TV show's airing status, normalized across providers.

  TMDB and TVDB describe the same states in different words. TMDB sends
  "Returning Series", "Ended", "Canceled", "In Production", "Planned" and
  "Pilot"; TVDB sends "Continuing", "Ended" and "Upcoming" (see
  `Mydia.Metadata.Provider.Relay.transform_tvdb_to_tmdb_format/4`, which copies
  TVDB's `status.name` through verbatim). Both land in `MediaMetadata.status`.

  Movies also carry a status ("Released", "Post Production"), which is not a
  show status, so the item and metadata readers return nil for anything that
  is not a TV show.
  """

  alias Mydia.Media.MediaItem
  alias Mydia.Metadata.Structs.MediaMetadata

  @type t :: :continuing | :ended | :canceled | :upcoming

  @statuses %{
    "Returning Series" => :continuing,
    "Continuing" => :continuing,
    "Ended" => :ended,
    "Canceled" => :canceled,
    "Cancelled" => :canceled,
    "In Production" => :upcoming,
    "Planned" => :upcoming,
    "Pilot" => :upcoming,
    "Upcoming" => :upcoming
  }

  @doc "Normalizes a raw provider status string, or nil when unrecognized."
  @spec normalize(term()) :: t() | nil
  def normalize(raw) when is_binary(raw), do: Map.get(@statuses, raw)
  def normalize(_raw), do: nil

  @doc "The status of a library item, or nil for movies and missing metadata."
  @spec for_item(term()) :: t() | nil
  def for_item(%MediaItem{type: "tv_show", metadata: %MediaMetadata{status: raw}}),
    do: normalize(raw)

  def for_item(_item), do: nil

  @doc "The status carried by fetched metadata, or nil for movies and nil."
  @spec for_metadata(term()) :: t() | nil
  def for_metadata(%MediaMetadata{media_type: :tv_show, status: raw}), do: normalize(raw)
  def for_metadata(_metadata), do: nil

  @doc "Human label for a normalized status."
  @spec label(t()) :: String.t()
  def label(:continuing), do: "Continuing"
  def label(:ended), do: "Ended"
  def label(:canceled), do: "Canceled"
  def label(:upcoming), do: "Upcoming"
end
