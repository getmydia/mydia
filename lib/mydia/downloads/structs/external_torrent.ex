defmodule Mydia.Downloads.Structs.ExternalTorrent do
  @moduledoc """
  A torrent sitting in a download client that Mydia does not manage.

  Derived, never persisted. It exists for exactly as long as the torrent is in
  the client and Mydia has neither tracked nor imported it, which is why there
  is no self-heal path and nothing to dismiss: the row disappears when the
  torrent does.

  `kind` is the split that decides where it renders:

    * `:needs_matching` — the name parses as a movie or a TV release, so Mydia
      offers to match it to the library (Issues tab)
    * `:external` — anything else, most often genuinely unrelated to Mydia
      (External tab)

  `seeders` / `leechers` are deliberately absent: adapters return
  `Mydia.Downloads.Structs.DownloadStatus`, which does not carry them.
  """

  alias Mydia.Library.Structs.ParsedFileInfo

  @enforce_keys [:id, :client_name, :client_id, :title, :kind]
  defstruct [
    :id,
    :client_name,
    :client_id,
    :title,
    :kind,
    :status,
    :progress,
    :size,
    :download_speed,
    :eta,
    :ratio,
    :save_path,
    :parsed,
    suggestions: []
  ]

  @type kind :: :needs_matching | :external

  @type suggestion :: %{
          media_item_id: binary(),
          title: String.t(),
          confidence: float(),
          match_reason: String.t()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          client_name: String.t(),
          client_id: String.t(),
          title: String.t(),
          kind: kind(),
          status: atom() | nil,
          progress: float() | nil,
          size: integer() | nil,
          download_speed: integer() | nil,
          eta: integer() | nil,
          ratio: float() | nil,
          save_path: String.t() | nil,
          parsed: ParsedFileInfo.t() | nil,
          suggestions: [suggestion()]
        }
end
