defmodule Mydia.Media.MinimumAvailability.Status do
  @moduledoc """
  Where a movie stands under its minimum availability level: the effective
  `level`, the date it becomes eligible (nil when there is none to wait for),
  and whether automatic search may look for it now. Built by
  `Mydia.Media.MinimumAvailability.status/3`.
  """

  @enforce_keys [:level, :eligible_on, :available?]
  defstruct [:level, :eligible_on, :available?]

  @type t :: %__MODULE__{level: String.t(), eligible_on: Date.t() | nil, available?: boolean()}
end
