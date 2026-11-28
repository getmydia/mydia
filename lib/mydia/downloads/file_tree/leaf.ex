defmodule Mydia.Downloads.FileTree.Leaf do
  @moduledoc "A file in a torrent file tree."

  alias Mydia.Downloads.Structs.TorrentFile

  @enforce_keys [:index, :name, :size, :file]
  defstruct [:index, :name, :size, :file, selected?: false]

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          name: String.t(),
          size: non_neg_integer(),
          selected?: boolean(),
          file: TorrentFile.t()
        }
end
