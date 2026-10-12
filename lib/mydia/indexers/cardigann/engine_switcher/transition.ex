defmodule Mydia.Indexers.Cardigann.EngineSwitcher.Transition do
  @moduledoc "A switch to the Prowlarr engine that has not cut over yet."

  @type t :: %__MODULE__{
          target: :prowlarr,
          phase: :pending | :fetching | :compiling | :failed,
          bytes: non_neg_integer() | nil,
          total: non_neg_integer() | nil,
          phase_started_at: DateTime.t(),
          error: String.t() | nil,
          next_retry_at: DateTime.t() | nil
        }

  @enforce_keys [:phase_started_at]
  defstruct target: :prowlarr,
            phase: :pending,
            bytes: nil,
            total: nil,
            phase_started_at: nil,
            error: nil,
            next_retry_at: nil
end
