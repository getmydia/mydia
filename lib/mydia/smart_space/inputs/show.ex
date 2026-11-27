defmodule Mydia.SmartSpace.Inputs.Show do
  @moduledoc """
  One TV show as the evaluator sees it. `override` is nil when the show
  inherits the global rule; otherwise `mode` is `"off"` or `"custom"`.
  `watches` holds every watch record on the show's episodes, watched or not.
  `in_flight_show?` holds the whole show back.
  """

  alias Mydia.SmartSpace.Inputs.{Episode, KeepRef, OverrideRule, Watch}

  @enforce_keys [:media_item_id]
  defstruct media_item_id: nil,
            title: nil,
            override: nil,
            episodes: [],
            keeps: [],
            watches: [],
            in_flight_show?: false

  @type t :: %__MODULE__{
          media_item_id: binary(),
          title: String.t() | nil,
          override: OverrideRule.t() | nil,
          episodes: [Episode.t()],
          keeps: [KeepRef.t()],
          watches: [Watch.t()],
          in_flight_show?: boolean()
        }
end
