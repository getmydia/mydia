defmodule Mydia.SmartSpace.Inputs do
  @moduledoc """
  Everything `Mydia.SmartSpace.Evaluator` needs, gathered up front so the
  evaluator itself never touches the Repo, the config or the clock.

  `global` is the global rule. `selected_user_ids` holds the resolved user
  ids for the `"selected"` policy, or `:misconfigured` when a configured
  username does not resolve, in which case nothing is eligible.
  """

  alias Mydia.SmartSpace.Inputs.{Global, Show}

  @enforce_keys [:global]
  defstruct global: nil, selected_user_ids: [], shows: []

  @type t :: %__MODULE__{
          global: Global.t(),
          selected_user_ids: [binary()] | :misconfigured,
          shows: [Show.t()]
        }
end
