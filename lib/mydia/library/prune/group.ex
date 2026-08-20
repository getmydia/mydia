defmodule Mydia.Library.Prune.Group do
  @moduledoc """
  One media item that holds more than one active file.

  A group is the unit the prune feature reasons about. `subject` is the thing
  that owns the files: an `%Episode{}` for TV, a `%MediaItem{}` for a movie.
  `media_item` is always the owning movie or show, which is what carries the
  quality profile and what `TargetContext.from_media_item/1` needs.
  """

  alias Mydia.Library.MediaFile
  alias Mydia.Media.{Episode, MediaItem}

  @enforce_keys [:subject_type, :subject_id, :subject, :media_item, :files]
  defstruct [:subject_type, :subject_id, :subject, :media_item, :files]

  @type subject_type :: :episode | :movie

  @type t :: %__MODULE__{
          subject_type: subject_type(),
          subject_id: String.t(),
          subject: Episode.t() | MediaItem.t(),
          media_item: MediaItem.t(),
          files: [MediaFile.t()]
        }
end
