defmodule Mydia.Subtitles.Scoring.Factor do
  @moduledoc """
  One scored dimension of a result, and why it earned what it earned.

  `detail` carries the reference's value, meaning what this media file is,
  so an unmatched row tells the operator what the subtitle failed to match
  rather than restating the subtitle's own name.

  `max` is this factor's ceiling. It rides on the struct so a renderer can
  colour a row by the fraction earned without keeping its own copy of the
  weight table, which would be free to drift from the real one.
  """

  @type t :: %__MODULE__{
          key: atom(),
          label: String.t(),
          detail: String.t() | nil,
          matched: boolean(),
          points: integer(),
          max: integer()
        }

  @enforce_keys [:key, :label, :matched, :points, :max]
  defstruct [:key, :label, :detail, :matched, :points, :max]
end
