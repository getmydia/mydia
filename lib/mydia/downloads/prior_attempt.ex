defmodule Mydia.Downloads.PriorAttempt do
  @moduledoc """
  A release that was already tried for a media target and did not work out:
  either its download failed (`:failed`) or it sits on the release blacklist
  (`:blacklisted`). Produced by `Mydia.Downloads.PriorAttempts`.
  """

  @enforce_keys [:kind, :at]
  defstruct [:kind, :reason, :at]

  @type t :: %__MODULE__{
          kind: :failed | :blacklisted,
          reason: String.t() | nil,
          at: DateTime.t()
        }
end
