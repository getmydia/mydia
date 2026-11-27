defmodule Mydia.SmartSpace.Cleanup do
  @moduledoc """
  One unit (a season or an episode) that Smart Space may move to the trash,
  with the files it covers and the moment it became eligible.
  """

  @enforce_keys [:media_item_id, :unit, :season_number, :eligible_at]
  defstruct media_item_id: nil,
            title: nil,
            unit: nil,
            season_number: nil,
            episode_ids: [],
            file_ids: [],
            bytes: 0,
            eligible_at: nil

  @type t :: %__MODULE__{
          media_item_id: binary(),
          title: String.t() | nil,
          unit: :season | :episode,
          season_number: integer(),
          episode_ids: [binary()],
          file_ids: [binary()],
          bytes: non_neg_integer(),
          eligible_at: DateTime.t()
        }
end
