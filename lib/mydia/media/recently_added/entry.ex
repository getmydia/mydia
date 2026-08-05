defmodule Mydia.Media.RecentlyAdded.Entry do
  @moduledoc """
  One item in the recently-added list, with the context needed to say what
  arrived rather than only when.
  """

  @type t :: %__MODULE__{
          media_item: struct(),
          content_added_at: DateTime.t(),
          new_episode_count: non_neg_integer() | nil,
          latest_episode: Mydia.Media.Episode.t() | nil
        }

  defstruct [:media_item, :content_added_at, :new_episode_count, :latest_episode]
end
