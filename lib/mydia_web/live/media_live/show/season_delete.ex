defmodule MydiaWeb.MediaLive.Show.SeasonDelete do
  @moduledoc """
  State of the "Delete season files" dialog: the season, the episodes it acts
  on, what will be removed (counted from
  `Mydia.Library.episode_files_for_removal/1`, so it matches the outcome), and
  the chosen mode and unmonitor flag.
  """

  @enforce_keys [:season_number, :episode_ids]
  defstruct season_number: nil,
            episode_ids: [],
            file_count: 0,
            bytes: 0,
            mode: :trash,
            unmonitor: true

  @type t :: %__MODULE__{
          season_number: integer(),
          episode_ids: [binary()],
          file_count: non_neg_integer(),
          bytes: non_neg_integer(),
          mode: :trash | :permanent | :library_only,
          unmonitor: boolean()
        }
end
