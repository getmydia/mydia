defmodule Mydia.Media.Posters.Candidate do
  @moduledoc """
  An image file in a media item's folder that can be chosen as its poster.

  `relative_path` is relative to the library path root, which is what
  `Mydia.Storage.source/2` takes.
  """

  @enforce_keys [:library_path_id, :relative_path, :name, :size]
  defstruct [:library_path_id, :relative_path, :name, :size]

  @type t :: %__MODULE__{
          library_path_id: String.t(),
          relative_path: String.t(),
          name: String.t(),
          size: non_neg_integer()
        }
end
