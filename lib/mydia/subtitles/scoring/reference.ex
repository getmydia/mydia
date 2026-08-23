defmodule Mydia.Subtitles.Scoring.Reference do
  @moduledoc """
  A release description in the release parser's standard vocabulary.

  Two things share this shape: `build_reference/1` builds one describing
  what the media file is, once per search, since parsing is the expensive
  half of scoring and that reference does not vary across candidates.
  `parse_candidate/1` builds another describing what a subtitle candidate's
  own file name claims to be, once per result, so the two can be compared
  field by field.
  """

  @type t :: %__MODULE__{
          release_group: String.t() | nil,
          resolution: String.t() | nil,
          source: String.t() | nil,
          codec: String.t() | nil,
          audio: String.t() | nil
        }

  defstruct [:release_group, :resolution, :source, :codec, :audio]
end
