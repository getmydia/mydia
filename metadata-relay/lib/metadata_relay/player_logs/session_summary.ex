defmodule MetadataRelay.PlayerLogs.SessionSummary do
  @moduledoc """
  One app launch on one device, summed over the chunks that mention it.
  """

  @enforce_keys [:first_t, :last_t, :lines]
  defstruct [:sid, :first_t, :last_t, :lines]

  @type t :: %__MODULE__{
          sid: String.t() | nil,
          first_t: integer(),
          last_t: integer(),
          lines: non_neg_integer()
        }
end
