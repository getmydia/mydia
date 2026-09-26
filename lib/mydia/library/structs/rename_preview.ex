defmodule Mydia.Library.Structs.RenamePreview do
  @moduledoc """
  One file's proposed rename, as shown in the show page's rename modal.

  `season_number` and `episode_number` come from the file's episode and are
  nil for movies. `changed?` is true when the proposed filename differs from
  the current one; only changed previews can be selected for renaming.
  """

  defstruct [
    :file_id,
    :current_path,
    :proposed_path,
    :current_filename,
    :proposed_filename,
    :directory,
    :extension,
    :season_number,
    :episode_number,
    changed?: false
  ]

  @type t :: %__MODULE__{
          file_id: String.t(),
          current_path: String.t(),
          proposed_path: String.t(),
          current_filename: String.t(),
          proposed_filename: String.t(),
          directory: String.t(),
          extension: String.t(),
          season_number: integer() | nil,
          episode_number: integer() | nil,
          changed?: boolean()
        }
end
