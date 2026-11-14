defmodule Mydia.Downloads.Structs.TorrentFile do
  @moduledoc """
  One file inside a torrent, as reported by a download client that supports
  per-file selection.

  `path` is relative to the torrent root. `included?` is whether the client
  will download the file, and `downloaded` is the bytes fetched so far.
  """

  @enforce_keys [:index, :path, :size]
  defstruct [:index, :path, :size, included?: true, downloaded: 0]

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          path: String.t(),
          size: non_neg_integer(),
          included?: boolean(),
          downloaded: non_neg_integer()
        }
end
