defmodule MydiaWeb.DownloadsLive.Summary do
  @moduledoc """
  Queue totals for the Downloads stats bar, built by
  `MydiaWeb.DownloadsLive.ListView.summarize/2` from the unfiltered Queue list
  so the numbers hold still while the operator types a search. `seeding`
  counts torrents still seeding after import (see `summarize/2`).
  """

  defstruct active: 0,
            seeding: 0,
            stalled: 0,
            download_speed: 0,
            upload_speed: 0,
            remaining_bytes: 0,
            eta_seconds: nil,
            stale_as_of: nil

  @type t :: %__MODULE__{
          active: non_neg_integer(),
          seeding: non_neg_integer(),
          stalled: non_neg_integer(),
          download_speed: number(),
          upload_speed: number(),
          remaining_bytes: non_neg_integer(),
          eta_seconds: non_neg_integer() | nil,
          stale_as_of: DateTime.t() | nil
        }
end
