defmodule Mydia.Media.DiskRemoval.Preview do
  @moduledoc """
  What deleting one item from disk would do, for the delete dialog. Built by
  `Mydia.Media.DiskRemoval.preview/1`. Advisory only: the delete checks every
  folder again.
  """

  alias Mydia.Library.ItemFolders

  defstruct remove: [], keep: [], loose_files: 0

  @type t :: %__MODULE__{
          remove: [String.t()],
          keep: [{String.t(), [ItemFolders.blocker()]}],
          loose_files: non_neg_integer()
        }
end
