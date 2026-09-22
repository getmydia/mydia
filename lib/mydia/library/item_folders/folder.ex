defmodule Mydia.Library.ItemFolders.Folder do
  @moduledoc """
  A folder that names one piece of media, found by
  `Mydia.Library.ItemFolders.folders_for/1`.

  `relative` is relative to `library_path.path`; `absolute` is the two joined.
  """

  alias Mydia.Settings.LibraryPath

  @enforce_keys [:library_path, :relative, :absolute]
  defstruct [:library_path, :relative, :absolute]

  @type t :: %__MODULE__{
          library_path: LibraryPath.t(),
          relative: String.t(),
          absolute: String.t()
        }
end
