defmodule Mydia.SmartSpace.Inputs.FileRef do
  @moduledoc """
  One live media file as the evaluator sees it: its id, its size, and every
  episode it covers. A multi-episode release (`S01E09E10`) covers several, so
  it may only be trashed when every one of them is due.
  """

  @enforce_keys [:id]
  defstruct id: nil, size: nil, episode_ids: []

  @type t :: %__MODULE__{
          id: binary(),
          size: non_neg_integer() | nil,
          episode_ids: [binary()]
        }
end
