defmodule Mydia.Downloads.Structs.EnrichedDownload do
  @moduledoc """
  Represents a download enriched with real-time status from the download client.

  This struct combines data from the Downloads database table with real-time
  torrent/NZB status from the download client (qBittorrent, Transmission, etc.).

  It's used as a view model for displaying download information in LiveViews
  and represents the current state of a download at any given moment.
  """

  alias Mydia.Downloads.Client.FailureCategory

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
    :match_status,
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
    # Client-reported failure detail. Deliberately SEPARATE from
    # `error_message`, which is bound to the database column: DownloadMonitor
    # uses `is_nil(error_message)` to find failures it hasn't handled yet
    # (lib/mydia/jobs/download_monitor.ex:91), so folding client detail into
    # it would make every failed download look already-handled.
    :client_failure_category,
    :client_error_detail,
    :db_completed_at,
    :imported_at,
    # Import retry tracking (displayed in Issues tab)
    :import_retry_count,
    :import_last_error,
    :import_failure_reason,
    :import_reported_path,
    :import_next_retry_at,
    :import_failed_at,
    # Issues-tab path-mapping enrichment (computed in the LiveView; nil otherwise)
    :path_mapping_suggestion,
    :path_mapping_affected_count,
    # Stall-detection / progress tracking (mirrored from Download DB row)
    :last_progress_at,
    :last_known_bytes,
    :last_observed_at,
    :stalled_since,
    # Whether the torrent is currently present in its download client.
    # true  = client confirmed the torrent is there
    # false = client confirmed the torrent is gone
    # nil   = client unreachable; presence unknown
    :in_client?,
    # Whether a completed download is eligible for post-import re-match: exactly
    # one non-trashed imported file (packs resolve to several and can't be
    # re-matched as a unit). Computed per-tab in the LiveView; nil when not
    # evaluated (e.g. queue/issues rows, where the action isn't offered).
    :rematch_eligible?
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
          match_status: String.t() | nil,
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
          client_failure_category: FailureCategory.t() | nil,
          client_error_detail: String.t() | nil,
          db_completed_at: DateTime.t() | nil,
          imported_at: DateTime.t() | nil,
          import_retry_count: integer() | nil,
          import_last_error: String.t() | nil,
          import_failure_reason: String.t() | nil,
          import_reported_path: String.t() | nil,
          import_next_retry_at: DateTime.t() | nil,
          import_failed_at: DateTime.t() | nil,
          path_mapping_suggestion: map() | nil,
          path_mapping_affected_count: integer() | nil,
          last_progress_at: DateTime.t() | nil,
          last_known_bytes: integer() | nil,
          last_observed_at: DateTime.t() | nil,
          stalled_since: DateTime.t() | nil,
          in_client?: boolean() | nil,
          rematch_eligible?: boolean() | nil
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
