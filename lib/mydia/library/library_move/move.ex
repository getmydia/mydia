defmodule Mydia.Library.LibraryMove.Move do
  @moduledoc """
  One file's planned move into another library. `conflict` is true when
  another file of the item already sits at, or is planned for, the same
  destination; the job skips such a file instead of placing it.
  """

  @enforce_keys [:media_file, :source_path, :dest_path, :dest_rel, :action]
  defstruct @enforce_keys ++ [conflict: false]

  @type t :: %__MODULE__{
          media_file: Mydia.Library.MediaFile.t(),
          source_path: String.t(),
          dest_path: String.t(),
          dest_rel: String.t(),
          action: :hardlink | :copy,
          conflict: boolean()
        }
end
