defmodule Mydia.SmartSpace.Inputs.Episode do
  @moduledoc """
  One episode: its live (not trashed) files as `{file_id, size}` pairs and
  whether a download or import is in flight for it. `air_date: nil` counts
  as unaired. `monitored` defaults to `true` so a missing value keeps media:
  under the season unit a monitored episode without files holds its season.
  """

  @enforce_keys [:id, :season_number]
  defstruct id: nil,
            season_number: nil,
            episode_number: nil,
            air_date: nil,
            files: [],
            monitored: true,
            in_flight?: false

  @type t :: %__MODULE__{
          id: binary(),
          season_number: integer(),
          episode_number: integer() | nil,
          air_date: Date.t() | nil,
          files: [{binary(), non_neg_integer() | nil}],
          monitored: boolean(),
          in_flight?: boolean()
        }
end
