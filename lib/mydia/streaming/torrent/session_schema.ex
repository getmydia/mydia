defmodule Mydia.Streaming.Torrent.SessionSchema do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "torrent_streaming_sessions" do
    field :release_title, :string
    field :infohash, :string
    field :magnet, :string
    field :file_id, :integer
    field :staging_path, :string
    field :total_bytes, :integer

    field :state, Ecto.Enum,
      values: [:initializing, :downloading, :ready, :watching, :completed, :failed, :cancelled]

    field :started_at, :utc_datetime
    field :last_progress_at, :utc_datetime
    field :download_progress, :float, default: 0.0

    belongs_to :media_item, Mydia.Media.MediaItem
    belongs_to :episode, Mydia.Media.Episode
    belongs_to :user, Mydia.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :release_title,
      :infohash,
      :magnet,
      :file_id,
      :staging_path,
      :total_bytes,
      :state,
      :started_at,
      :last_progress_at,
      :download_progress,
      :media_item_id,
      :episode_id,
      :user_id
    ])
    |> validate_required([:release_title, :magnet, :state, :started_at, :user_id])
    |> validate_number(:download_progress,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
  end
end
