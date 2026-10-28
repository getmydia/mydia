defmodule Mydia.Library.LibraryMove.Move do
  @moduledoc "One file's planned move into another library."

  @enforce_keys [:media_file, :source_path, :dest_path, :dest_rel, :action]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          media_file: Mydia.Library.MediaFile.t(),
          source_path: String.t(),
          dest_path: String.t(),
          dest_rel: String.t(),
          action: :hardlink | :copy
        }
end
