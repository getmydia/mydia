defmodule Mydia.Playback.Progress do
  @moduledoc """
  Schema for tracking playback progress for media files.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: binary(),
          position_seconds: integer() | nil,
          duration_seconds: integer() | nil,
          completion_percentage: float() | nil,
          watched: boolean(),
          last_watched_at: DateTime.t() | nil,
          user: Mydia.Accounts.User.t() | Ecto.Association.NotLoaded.t(),
          media_item: Mydia.Media.MediaItem.t() | Ecto.Association.NotLoaded.t(),
          episode: Mydia.Media.Episode.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "playback_progress" do
    field :position_seconds, :integer
    field :duration_seconds, :integer
    field :completion_percentage, :float
    field :watched, :boolean, default: false
    field :last_watched_at, :utc_datetime

    belongs_to :user, Mydia.Accounts.User
    belongs_to :media_item, Mydia.Media.MediaItem
    belongs_to :episode, Mydia.Media.Episode

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating playback progress.

  ## Options

    * `:authoritative_watched` - when true, skip the 90% auto-mark so a sync
      import can preserve the remote's own watched flag
  """
  def changeset(progress, attrs, opts \\ []) do
    progress
    |> cast(attrs, [
      :user_id,
      :media_item_id,
      :episode_id,
      :position_seconds,
      :duration_seconds,
      :completion_percentage,
      :watched,
      :last_watched_at
    ])
    |> validate_required([:user_id, :position_seconds, :duration_seconds])
    |> validate_one_parent()
    |> validate_number(:position_seconds, greater_than_or_equal_to: 0)
    |> validate_number(:duration_seconds, greater_than: 0)
    |> calculate_completion_percentage()
    |> auto_mark_watched(Keyword.get(opts, :authoritative_watched, false))
    |> set_last_watched_at()
    |> unique_constraint([:user_id, :media_item_id])
    |> unique_constraint([:user_id, :episode_id])
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

  # Calculate completion percentage based on position and duration
  defp calculate_completion_percentage(changeset) do
    position = get_field(changeset, :position_seconds)
    duration = get_field(changeset, :duration_seconds)

    if position && duration && duration > 0 do
      # Capped at 100: a client that posts a position beyond the duration it
      # knew at the time (which an HLS stream reporting a partial playlist
      # length will do) must not produce a percentage above 100, which would
      # render as an overflowing progress bar.
      percentage = min(position / duration * 100.0, 100.0)
      put_change(changeset, :completion_percentage, percentage)
    else
      changeset
    end
  end

  # When a sync carries the remote's own watched flag, that flag is the truth.
  # Auto-marking at 90% would silently override it and diverge from the server.
  defp auto_mark_watched(changeset, true), do: changeset

  defp auto_mark_watched(changeset, false) do
    percentage = get_field(changeset, :completion_percentage)

    if percentage && percentage >= 90.0 do
      put_change(changeset, :watched, true)
    else
      changeset
    end
  end

  # Set last_watched_at to current time if not provided
  defp set_last_watched_at(changeset) do
    if get_change(changeset, :last_watched_at) do
      changeset
    else
      put_change(changeset, :last_watched_at, DateTime.utc_now() |> DateTime.truncate(:second))
    end
  end
end
