defmodule Mydia.SmartSpace.Cleanup do
  @moduledoc """
  One unit (a season or an episode) that Smart Space may move to the trash,
  with the files it covers and the moment it became eligible.

  `files` carries every file with the episodes it covers, so the job can keep
  all of them monitored when the file fails to move. `file_ids` and `bytes`
  are derived from it.
  """

  alias Mydia.SmartSpace.Inputs.FileRef

  @enforce_keys [:media_item_id, :unit, :season_number, :eligible_at]
  defstruct media_item_id: nil,
            title: nil,
            unit: nil,
            season_number: nil,
            episode_ids: [],
            file_ids: [],
            files: [],
            bytes: 0,
            eligible_at: nil

  @type t :: %__MODULE__{
          media_item_id: binary(),
          title: String.t() | nil,
          unit: :season | :episode,
          season_number: integer(),
          episode_ids: [binary()],
          file_ids: [binary()],
          files: [FileRef.t()],
          bytes: non_neg_integer(),
          eligible_at: DateTime.t()
        }
end
