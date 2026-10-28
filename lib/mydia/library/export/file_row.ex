defmodule Mydia.Library.Export.FileRow do
  @moduledoc """
  One media file in a library export. Field order here is the column order of
  the per-file CSV (after the item identity columns) and the key order of each
  entry in a JSON item's `files` array.

  `library_path` is the root the file actually lives under, which can differ
  from its item's assigned library. `video_profile`, `bit_depth` and
  `audio_channels` come from `metadata.streams` (see
  `lib/mydia/streaming/README.md`). `episode` is a string so a multi-episode
  file can report its episodes within its season: a consecutive run as a range
  (`"4-5"`), anything else as a list (`"1,3"`).
  """

  @fields [
    :path,
    :library_path,
    :size_bytes,
    :resolution,
    :video_codec,
    :video_profile,
    :bit_depth,
    :hdr_format,
    :audio_codec,
    :audio_channels,
    :container,
    :season,
    :episode
  ]

  defstruct @fields

  @type t :: %__MODULE__{
          path: String.t() | nil,
          library_path: String.t() | nil,
          size_bytes: non_neg_integer() | nil,
          resolution: String.t() | nil,
          video_codec: String.t() | nil,
          video_profile: String.t() | nil,
          bit_depth: integer() | nil,
          hdr_format: String.t() | nil,
          audio_codec: String.t() | nil,
          audio_channels: String.t() | nil,
          container: String.t() | nil,
          season: integer() | nil,
          episode: String.t() | nil
        }

  @doc "Field names in export column order."
  @spec fields() :: [atom()]
  def fields, do: @fields
end
