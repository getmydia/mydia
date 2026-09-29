defmodule Mydia.Library.Misfile.Finding do
  @moduledoc """
  One media item with at least one suspect file, as `Mydia.Library.Misfile.scan/0`
  reports it. `file_count` counts every active file on the item, extras
  included, so a caller can tell whether sending the suspects would empty it.
  """

  alias Mydia.Library.MediaFile
  alias Mydia.Media.MediaItem

  @enforce_keys [:media_item, :file_count, :suspects, :nothing_binds?]
  defstruct [:media_item, :file_count, :suspects, :nothing_binds?]

  @type t :: %__MODULE__{
          media_item: MediaItem.t(),
          file_count: non_neg_integer(),
          suspects: [{MediaFile.t(), Mydia.Library.Misfile.reason()}],
          nothing_binds?: boolean()
        }
end
