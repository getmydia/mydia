defmodule MetadataRelay.PlayerLogs.Batch do
  @moduledoc """
  One decoded `POST /player-logs` body. `size` is the decompressed byte count,
  which is what the daily quota charges; `dropped` counts records that did not
  validate.
  """

  alias MetadataRelay.PlayerLogs.{Meta, Record}

  @enforce_keys [:meta]
  defstruct [:meta, records: [], size: 0, dropped: 0]

  @type t :: %__MODULE__{
          meta: Meta.t(),
          records: [Record.t()],
          size: non_neg_integer(),
          dropped: non_neg_integer()
        }
end
