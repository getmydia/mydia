defmodule Mydia.SmartSpace.Inputs.Watch do
  @moduledoc "One user's playback record on one episode."

  @enforce_keys [:user_id, :episode_id]
  defstruct user_id: nil, episode_id: nil, watched: false, last_watched_at: nil

  @type t :: %__MODULE__{
          user_id: binary(),
          episode_id: binary(),
          watched: boolean(),
          last_watched_at: DateTime.t() | nil
        }
end
