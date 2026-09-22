defmodule MetadataRelay.PlayerLogs.Record do
  @moduledoc """
  One validated log line. `line` is the record re-encoded from its validated
  fields, without a trailing newline, and is what gets stored.
  """

  @enforce_keys [:t, :line]
  defstruct [:t, :sid, :line]

  @type t :: %__MODULE__{t: integer(), sid: String.t() | nil, line: String.t()}
end
