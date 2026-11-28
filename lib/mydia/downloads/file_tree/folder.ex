defmodule Mydia.Downloads.FileTree.Folder do
  @moduledoc """
  A folder in a torrent file tree. `path` is relative to the torrent root and
  is `""` for a synthetic root. `selected_size` totals the selected files below.
  """

  alias Mydia.Downloads.FileTree.Leaf

  @enforce_keys [:path, :name]
  defstruct [:path, :name, children: [], size: 0, selected_size: 0, state: :none]

  @type t :: %__MODULE__{
          path: String.t(),
          name: String.t(),
          children: [t() | Leaf.t()],
          size: non_neg_integer(),
          selected_size: non_neg_integer(),
          state: :all | :none | :partial
        }
end
