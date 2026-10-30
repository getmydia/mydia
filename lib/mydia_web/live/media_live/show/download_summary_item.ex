defmodule MydiaWeb.MediaLive.Show.DownloadSummaryItem do
  @moduledoc """
  One active download in a `MydiaWeb.MediaLive.Show.DownloadSummary`, with
  what it is for: a single episode, a season pack, or something the page can
  only name by its release title.
  """

  @enforce_keys [:download, :kind, :sort_key]
  defstruct [:download, :kind, :season_number, :episode_number, :sort_key]

  @type kind :: :episode | :season_pack | :other
  @type t :: %__MODULE__{
          download: map(),
          kind: kind(),
          season_number: integer() | nil,
          episode_number: integer() | nil,
          sort_key: term()
        }
end
