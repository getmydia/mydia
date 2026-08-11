defmodule Mydia.Downloads.Structs.DownloadStatus do
  @moduledoc """
  Represents the status of a download item (torrent or NZB) from a download client.

  This struct provides compile-time safety for download status data across all
  download clients (qBittorrent, Transmission, rTorrent, Blackhole, SABnzbd,
  NZBGet), replacing plain map access that can silently return nil.

  The struct is intentionally name-agnostic across torrent and Usenet downloads:
  every adapter normalises its client-specific state strings into the shared
  `t:state/0` taxonomy listed below.

  ## State taxonomy

  The `:state` field is one of:

    * `:downloading` — actively receiving data (includes torrent "stalledDL",
      NZB "Downloading"/"Fetching"/"Queued")
    * `:seeding` — torrent-only; post-completion upload phase
    * `:paused` — manually paused by the user
    * `:checking` — verifying/repairing/unpacking/moving. NZB post-processing
      ("Verifying"/"Repairing"/"Extracting"/"Moving") lands here so the
      DownloadMonitor doesn't prematurely flag the download as missing
    * `:queued` — waiting to start (reserved; some adapters fold this into
      `:downloading` to match client conventions)
    * `:error` — terminal failure
    * `:completed` — terminal success
    * `:unknown` — fallback for unrecognised values
  """

  alias Mydia.Downloads.Client.FailureCategory

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
    :completed_at,
    # Why the client reported a terminal failure, in its own words. Both are
    # nil unless `state == :error`, and stay nil for adapters that don't yet
    # classify their failures. See `Mydia.Downloads.Client.FailureCategory`.
    :failure_category,
    :failure_detail,
    # A path that scopes THIS torrent/NZB's data, so MediaImport can import it
    # instead of recursively listing `save_path` (clients like rqbit share one
    # output folder across many torrents, and a recursive listing would
    # cross-contaminate libraries).
    #
    # NOT a reliable file listing. Transmission and rqbit populate it with
    # real leaf paths, but qBittorrent reports a single `content_path` and
    # rtorrent a single `base_path`, either of which is usually the torrent's
    # root DIRECTORY. Anything that needs to know what is actually inside a
    # torrent must use `Mydia.Downloads.Client.list_files/3` instead.
    files: nil
  ]

  @state_values [
    :downloading,
    :seeding,
    :paused,
    :checking,
    :queued,
    :error,
    :completed,
    :unknown
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
          files: [String.t()] | nil,
          added_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          failure_category: FailureCategory.t() | nil,
          failure_detail: String.t() | nil
        }

  @doc """
  Returns the full set of valid state atoms.

  Each adapter's `parse_state/1` MUST return a value from this list.
  """
  @spec state_values() :: [state()]
  def state_values, do: @state_values

  @doc """
  Creates a new DownloadStatus struct from a map or keyword list.

  ## Examples

      iex> new(id: "abc123", name: "Movie.mkv", state: :downloading, progress: 50.0)
      %DownloadStatus{
        id: "abc123",
        name: "Movie.mkv",
        state: :downloading,
        progress: 50.0,
        download_speed: nil,
        ...
      }
  """
  @spec new(map() | keyword()) :: t()
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    struct(__MODULE__, attrs)
  end
end
