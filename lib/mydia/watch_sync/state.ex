defmodule Mydia.WatchSync.State do
  @moduledoc """
  Per-user last-agreed watch state between local and a remote provider.

  This is the only record that an item was ever watched, because a local
  unwatch deletes the playback_progress row outright and emits no event.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: binary(),
          provider: String.t(),
          provider_instance_id: String.t(),
          synced_watched: boolean(),
          synced_position_seconds: integer() | nil,
          synced_at: DateTime.t() | nil,
          remote_last_watched_at: DateTime.t() | nil,
          user: Mydia.Accounts.User.t() | Ecto.Association.NotLoaded.t(),
          media_item: Mydia.Media.MediaItem.t() | Ecto.Association.NotLoaded.t(),
          episode: Mydia.Media.Episode.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "watch_sync_states" do
    field :provider, :string
    field :provider_instance_id, :string
    field :synced_watched, :boolean, default: false
    field :synced_position_seconds, :integer
    field :synced_at, :utc_datetime
    field :remote_last_watched_at, :utc_datetime

    belongs_to :user, Mydia.Accounts.User
    belongs_to :media_item, Mydia.Media.MediaItem
    belongs_to :episode, Mydia.Media.Episode

    timestamps(type: :utc_datetime)
  end

  def changeset(state, attrs) do
    state
    |> cast(attrs, [
      :user_id,
      :provider,
      :provider_instance_id,
      :media_item_id,
      :episode_id,
      :synced_watched,
      :synced_position_seconds,
      :synced_at,
      :remote_last_watched_at
    ])
    |> validate_required([:user_id, :provider, :provider_instance_id])
    |> validate_one_parent()
    |> unique_constraint([:user_id, :provider, :provider_instance_id, :media_item_id],
      name: :watch_sync_states_movie_index
    )
    |> unique_constraint([:user_id, :provider, :provider_instance_id, :episode_id],
      name: :watch_sync_states_episode_index
    )
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:media_item_id)
    |> foreign_key_constraint(:episode_id)
  end

  # Ensure either media_item_id or episode_id is set, but not both
  defp validate_one_parent(changeset) do
    media_item_id = get_field(changeset, :media_item_id)
    episode_id = get_field(changeset, :episode_id)

    cond do
      is_nil(media_item_id) and is_nil(episode_id) ->
        add_error(changeset, :media_item_id, "either media_item_id or episode_id must be set")

      not is_nil(media_item_id) and not is_nil(episode_id) ->
        add_error(changeset, :media_item_id, "cannot set both media_item_id and episode_id")

      true ->
        changeset
    end
  end
end
