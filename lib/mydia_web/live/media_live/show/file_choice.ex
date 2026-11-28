defmodule MydiaWeb.MediaLive.Show.FileChoice do
  @moduledoc """
  The `file_choice` assign of the media show page: one open "Choose files…"
  modal. `status` is `:loading`, `:ready` or `{:error, reason}`. The preview
  (which can hold a `.torrent` body) is kept only while the modal is open.
  See `MydiaWeb.MediaLive.Show.FileChoiceEvents`.
  """

  alias Mydia.Downloads.FileTree
  alias Mydia.Downloads.Queue.FilePreview
  alias Mydia.Downloads.WantedFiles

  @enforce_keys [:ref, :title]
  defstruct [:ref, :title, :preview, status: :loading, files: [], selected: MapSet.new()]

  @type status :: :loading | :ready | {:error, term()}

  @type t :: %__MODULE__{
          ref: String.t(),
          title: String.t(),
          status: status(),
          preview: FilePreview.t() | nil,
          files: [WantedFiles.file_map()],
          selected: FileTree.selection()
        }
end
