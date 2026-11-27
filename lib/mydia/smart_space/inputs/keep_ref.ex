defmodule Mydia.SmartSpace.Inputs.KeepRef do
  @moduledoc """
  A keep on a show, a season (`season_number` set) or an episode
  (`episode_id` set).
  """

  @enforce_keys [:level]
  defstruct level: nil, season_number: nil, episode_id: nil

  @type t :: %__MODULE__{
          level: :show | :season | :episode,
          season_number: integer() | nil,
          episode_id: binary() | nil
        }
end
