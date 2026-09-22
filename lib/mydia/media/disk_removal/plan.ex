defmodule Mydia.Media.DiskRemoval.Plan do
  @moduledoc """
  What `Mydia.Media.DiskRemoval.run/1` will remove, collected by
  `Mydia.Media.DiskRemoval.plan/1` while the rows that name it still exist.
  """

  alias Mydia.Library.ItemFolders.Folder
  alias Mydia.Library.MediaFile

  defstruct files: [], subtitle_paths: %{}, folders: []

  @type t :: %__MODULE__{
          files: [MediaFile.t()],
          subtitle_paths: %{binary() => [String.t()]},
          folders: [Folder.t()]
        }
end
