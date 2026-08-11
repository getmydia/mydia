defmodule Mydia.Search.SearchBackoff do
  @moduledoc """
  Schema for tracking search backoff state.

  When searches fail or return no usable results, we apply exponential backoff
  to avoid hammering indexers with repeated failing queries. This tracks the
  backoff state per resource (movie, tv_show, season, episode).

  ## Backoff Schedule

  15min → 30min → 1hr → 4hr → 12hr → 24hr → 3 days → 7 days (cap)

  ## Resource Types

  - `"movie"` - Per-movie backoff for the missing-file search path, resource_id = media_item.id
  - `"tv_show"` - Per-show backoff, resource_id = media_item.id
  - `"season"` - Per-season backoff, resource_id = media_item.id, season_number set
  - `"episode"` - Per-episode backoff for the missing-file search path, resource_id = episode.id
  - `"movie_upgrade"` - Per-movie backoff for the quality-upgrade search path, resource_id =
    media_item.id. Deliberately namespaced apart from `"movie"`: a movie's file-presence state
    changes over time (imported, then later trashed), so a backoff row from one search path must
    not suppress the other once a movie crosses that boundary. See `Mydia.Upgrades.eligible_movies/1`.
  - `"episode_upgrade"` - Per-episode backoff for the quality-upgrade search path, resource_id =
    episode.id. Namespaced apart from `"episode"` for the same reason as `"movie_upgrade"`: an
    episode's file-presence state changes over time, so a backoff row from one search path must
    not suppress the other once an episode crosses that boundary. See
    `Mydia.Upgrades.eligible_episodes/1`.
  - `"season_upgrade"` - Per-season backoff for the quality-upgrade season-pack search path,
    resource_id = media_item.id, season_number set. Namespaced apart from `"season"` (which
    nothing currently reads for eligibility - unlike the other `_upgrade` buckets above, this
    split isn't about file-presence races) so `Mydia.Jobs.UpgradeSweep` can suppress repeat
    season-pack upgrade searches for a season that keeps finding no qualifying pack, without
    also touching the ordinary missing-episode `"season"` bucket.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @type t :: %__MODULE__{
          id: binary(),
          resource_type: String.t() | nil,
          resource_id: binary() | nil,
          season_number: integer() | nil,
          failure_count: integer(),
          last_failure_reason: String.t() | nil,
          next_eligible_at: DateTime.t() | nil,
          first_failed_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "search_backoffs" do
    field :resource_type, :string
    field :resource_id, :binary_id
    field :season_number, :integer
    field :failure_count, :integer, default: 0
    field :last_failure_reason, :string
    field :next_eligible_at, :utc_datetime
    field :first_failed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(backoff, attrs) do
    backoff
    |> cast(attrs, [
      :resource_type,
      :resource_id,
      :season_number,
      :failure_count,
      :last_failure_reason,
      :next_eligible_at,
      :first_failed_at
    ])
    |> validate_required([:resource_type, :resource_id])
    |> validate_inclusion(:resource_type, [
      "movie",
      "tv_show",
      "season",
      "episode",
      "movie_upgrade",
      "episode_upgrade",
      "season_upgrade",
      # Consecutive DownloadMonitor auto-rejections for one media item
      # (see Mydia.Jobs.DownloadMonitor).
      "auto_reject"
    ])
  end
end
