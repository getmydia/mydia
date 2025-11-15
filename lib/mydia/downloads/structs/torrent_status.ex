defmodule Mydia.Downloads.Structs.TorrentStatus do
  @moduledoc """
  Represents the status of a download item (torrent or NZB) from a download client.

  This struct provides compile-time safety for download status data across all
  download clients (qBittorrent, Transmission, SABnzbd, NZBGet), replacing
  plain map access that can silently return nil.
  """

  @enforce_keys [:id, :name, :state, :progress]

  defstruct [
    :id,
    :name,
    :state,
    :progress,
    :download_speed,
    :upload_speed,
    :downloaded,
    :uploaded,
    :size,
    :eta,
    :ratio,
    :save_path,
    :added_at,
    :completed_at
  ]

  @type state ::
          :downloading
          | :seeding
          | :paused
          | :checking
          | :queued
          | :error
          | :completed
          | :unknown

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          state: state(),
          progress: float(),
          download_speed: integer(),
          upload_speed: integer(),
          downloaded: integer(),
          uploaded: integer(),
          size: integer(),
          eta: integer() | nil,
          ratio: float(),
          save_path: String.t(),
          added_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil
        }

  @doc """
  Creates a new TorrentStatus struct from a map or keyword list.

  ## Examples

      iex> new(id: "abc123", name: "Movie.mkv", state: :downloading, progress: 50.0)
      %TorrentStatus{
        id: "abc123",
        name: "Movie.mkv",
        state: :downloading,
        progress: 50.0,
        download_speed: nil,
        ...
      }
  """
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    struct(__MODULE__, attrs)
  end
end
