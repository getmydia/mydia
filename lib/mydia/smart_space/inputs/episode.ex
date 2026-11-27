defmodule Mydia.SmartSpace.Inputs.Episode do
  @moduledoc """
  One episode: its live (not trashed) files as `{file_id, size}` pairs and
  whether a download or import is in flight for it. `air_date: nil` counts
  as unaired.
  """

  @enforce_keys [:id, :season_number]
  defstruct id: nil,
            season_number: nil,
            episode_number: nil,
            air_date: nil,
            files: [],
            in_flight?: false

  @type t :: %__MODULE__{
          id: binary(),
          season_number: integer(),
          episode_number: integer() | nil,
          air_date: Date.t() | nil,
          files: [{binary(), non_neg_integer() | nil}],
          in_flight?: boolean()
        }
end
