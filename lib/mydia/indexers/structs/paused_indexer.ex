defmodule Mydia.Indexers.Structs.PausedIndexer do
  @moduledoc """
  A Prowlarr indexer that Prowlarr has paused after failures.

  Prowlarr backs a failing indexer off on an escalating ladder (1m up to 24h)
  and drops it from every search until `disabled_till`. Mydia only reports
  this; Prowlarr owns the backoff.

  `id` is Prowlarr's own integer indexer id, not a Mydia config id. Encodable
  to JSON because it rides inside indexer health details, which the REST API
  serves.
  """

  @derive Jason.Encoder
  @enforce_keys [:id, :name, :disabled_till]
  defstruct [:id, :name, :disabled_till]

  @type t :: %__MODULE__{
          id: integer(),
          name: String.t(),
          disabled_till: DateTime.t()
        }
end
