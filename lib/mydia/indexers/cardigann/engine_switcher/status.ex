defmodule Mydia.Indexers.Cardigann.EngineSwitcher.Status do
  @moduledoc "What the Indexers page shows about the Cardigann engine."

  alias Mydia.Indexers.Cardigann.EngineSwitcher.Transition

  @type engine :: :builtin | :prowlarr
  @type t :: %__MODULE__{
          desired: engine(),
          active: engine(),
          transition: Transition.t() | nil,
          locked: boolean()
        }

  defstruct desired: :builtin, active: :builtin, transition: nil, locked: false
end
