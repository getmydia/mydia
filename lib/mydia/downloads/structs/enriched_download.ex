defmodule Mydia.Downloads.Structs.EnrichedDownload do
  @moduledoc """
  Represents a download enriched with real-time status from the download client.

  This struct combines data from the Downloads database table with real-time
  torrent/NZB status from the download client (qBittorrent, Transmission, etc.).

  It's used as a view model for displaying download information in LiveViews
  and represents the current state of a download at any given moment.
  """

  @enforce_keys [:id, :title, :download_client, :status]

  defstruct [
    # Database fields
    :id,
    :media_item_id,
    :episode_id,
    :media_item,
    :episode,
    :title,
    :indexer,
    :download_url,
    :download_client,
    :download_client_id,
    :metadata,
    :inserted_at,
    # Real-time status fields
    :status,
    :progress,
    :download_speed,
    :upload_speed,
    :eta,
    :size,
    :downloaded,
    :uploaded,
    :ratio,
    :seeders,
    :leechers,
    :save_path,
    :completed_at,
    :error_message,
    :db_completed_at
  ]

  @type t :: %__MODULE__{
          # Database fields
          id: binary(),
          media_item_id: binary() | nil,
          episode_id: binary() | nil,
          media_item: struct() | nil,
          episode: struct() | nil,
          title: String.t(),
          indexer: String.t(),
          download_url: String.t(),
          download_client: String.t(),
          download_client_id: String.t(),
          metadata: map(),
          inserted_at: DateTime.t(),
          # Real-time status fields
          status: String.t(),
          progress: float(),
          download_speed: integer(),
          upload_speed: integer(),
          eta: integer() | nil,
          size: integer(),
          downloaded: integer(),
          uploaded: integer(),
          ratio: float(),
          seeders: integer() | nil,
          leechers: integer() | nil,
          save_path: String.t() | nil,
          completed_at: DateTime.t() | nil,
          error_message: String.t() | nil,
          db_completed_at: DateTime.t() | nil
        }

  @doc """
  Creates a new EnrichedDownload struct from a map or keyword list.

  ## Examples

      iex> new(id: "abc123", title: "Movie", download_client: "qbittorrent", status: "downloading")
      %EnrichedDownload{
        id: "abc123",
        title: "Movie",
        download_client: "qbittorrent",
        status: "downloading",
        ...
      }
  """
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    struct(__MODULE__, attrs)
  end
end
