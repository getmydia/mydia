defmodule Mydia.Downloads.Download do
  @moduledoc """
  Schema for download queue items.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: binary(),
          indexer: String.t() | nil,
          title: String.t() | nil,
          download_url: String.t() | nil,
          download_client: String.t() | nil,
          download_client_id: String.t() | nil,
          completed_at: DateTime.t() | nil,
          error_message: String.t() | nil,
          metadata: map() | nil,
          match_status: String.t() | nil,
          imported_at: DateTime.t() | nil,
          import_retry_count: integer(),
          import_last_error: String.t() | nil,
          import_failure_reason: String.t() | nil,
          import_reported_path: String.t() | nil,
          import_next_retry_at: DateTime.t() | nil,
          import_failed_at: DateTime.t() | nil,
          last_progress_at: DateTime.t() | nil,
          last_known_bytes: integer(),
          last_observed_at: DateTime.t() | nil,
          stalled_since: DateTime.t() | nil,
          bytes_pulled: integer() | nil,
          content_checked_at: DateTime.t() | nil,
          media_item: Mydia.Media.MediaItem.t() | Ecto.Association.NotLoaded.t(),
          episode: Mydia.Media.Episode.t() | nil | Ecto.Association.NotLoaded.t(),
          library_path: Mydia.Settings.LibraryPath.t() | nil | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "downloads" do
    field :indexer, :string
    field :title, :string
    field :download_url, :string
    field :download_client, :string
    field :download_client_id, :string
    field :completed_at, :utc_datetime
    field :error_message, :string
    field :metadata, Mydia.Settings.JsonMapType
    field :match_status, :string

    # Import tracking fields
    field :imported_at, :utc_datetime
    field :import_retry_count, :integer, default: 0
    field :import_last_error, :string
    # Structured failure classification (e.g. "path_mapping_mismatch") so the
    # Issues tab can filter without parsing the human `import_last_error` string.
    field :import_failure_reason, :string
    # The client-reported path Mydia could not see, persisted so the Issues tab
    # can compute a path-mapping suggestion after the job has finished.
    field :import_reported_path, :string
    field :import_next_retry_at, :utc_datetime
    field :import_failed_at, :utc_datetime

    # Stall-detection / progress tracking fields. `last_progress_at` is the
    # timestamp of the last observed bytes-downloaded increment; `last_known_bytes`
    # is the byte count at that moment. Used by the stall-detection circuit
    # breaker to avoid polling stuck downloads forever.
    field :last_progress_at, :utc_datetime_usec
    field :last_known_bytes, :integer, default: 0

    # Observation + soft-stall tracking. `last_observed_at` is the timestamp of
    # the last poll in which this download was observed actively downloading; a
    # gap since this value resets the stall clock (so an outage/restart can't
    # false-stall a live torrent). `stalled_since` marks a recoverable soft
    # stall, kept distinct from the terminal `import_failed_at` so the episode
    # stays occupied until escalation. See `Mydia.Downloads.StallDetector`.
    field :last_observed_at, :utc_datetime_usec
    field :stalled_since, :utc_datetime_usec

    # Bytes streamed locally into staging by the debrid Fetcher (or any future
    # adapter that performs a separate post-completion local pull). Updated
    # atomically every 8 MB during streaming so the Range-resume recovery path
    # in `Fetcher.init/1` knows where to resume after a crash. Nil for adapters
    # that don't perform a local pull.
    field :bytes_pulled, :integer

    # Set once DownloadMonitor has successfully enumerated this torrent's
    # files for the pre-completion content check. Nil means "not yet
    # evaluated"; once set, the enumeration is never repeated. See
    # Mydia.Jobs.DownloadMonitor.evaluate_content/1.
    field :content_checked_at, :utc_datetime

    belongs_to :media_item, Mydia.Media.MediaItem
    belongs_to :episode, Mydia.Media.Episode

    # For specialized library downloads (music, books, adult) that don't have
    # a media_item, this field indicates which library to import files to
    belongs_to :library_path, Mydia.Settings.LibraryPath

    timestamps(type: :utc_datetime, updated_at: :updated_at)
  end

  @doc """
  Composable query scope for downloads that still "occupy" their episode/season —
  i.e. work is still in flight toward a successful import, so a second release must
  not be grabbed for the same target.

  A download occupies its target unless it has reached a terminal state:

    * imported successfully (`imported_at` set), or
    * the client-side download failed (`error_message` set), or
    * the import failed *terminally* with no further retries scheduled
      (`import_failed_at` set AND `import_next_retry_at` is nil).

  Everything else is occupying: actively downloading, downloaded-but-awaiting-import,
  and import-retrying (transient failures still have `import_next_retry_at` set).

  Note: a transient import failure sets `import_failed_at` on the first attempt
  (see `MediaImport.handle_import_failure/3`), so `import_failed_at` alone does not
  mean "done" — the `import_next_retry_at` nil check distinguishes terminal from
  retrying.
  """
  def occupying(query \\ __MODULE__) do
    from(d in query,
      where:
        is_nil(d.imported_at) and is_nil(d.error_message) and
          (is_nil(d.import_failed_at) or not is_nil(d.import_next_retry_at))
    )
  end

  @doc """
  Changeset for creating or updating a download.
  """
  def changeset(download, attrs) do
    download
    |> cast(attrs, [
      :media_item_id,
      :episode_id,
      :library_path_id,
      :indexer,
      :title,
      :download_url,
      :download_client,
      :download_client_id,
      :completed_at,
      :error_message,
      :metadata,
      :match_status,
      :imported_at,
      :import_retry_count,
      :import_last_error,
      :import_failure_reason,
      :import_reported_path,
      :import_next_retry_at,
      :import_failed_at,
      :last_progress_at,
      :last_known_bytes,
      :last_observed_at,
      :stalled_since,
      :bytes_pulled,
      :content_checked_at
    ])
    |> validate_required([:title])
    |> validate_inclusion(:match_status, ["unresolved_files", "partial_pack"])
    |> foreign_key_constraint(:media_item_id)
    |> foreign_key_constraint(:episode_id)
    |> foreign_key_constraint(:library_path_id)
    |> unique_constraint([:download_client, :download_client_id],
      message: "download already exists for this torrent"
    )
  end
end
