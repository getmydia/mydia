defmodule Mydia.Library.MediaFileEpisode do
  @moduledoc """
  Join between a media file and every episode it contains.

  Most files hold one episode and have exactly one row here. A multi-episode
  release (`S01E09E10`) holds several, and gets one row per episode, so none of
  them reads as missing while the content sits on disk.

  `media_files.episode_id` remains the primary (first) episode for the many
  callers that join on it directly; this table is the complete set.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: binary(),
          media_file_id: binary() | nil,
          episode_id: binary() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "media_file_episodes" do
    belongs_to :media_file, Mydia.Library.MediaFile
    belongs_to :episode, Mydia.Media.Episode

    timestamps(type: :utc_datetime)
  end

  def changeset(media_file_episode, attrs) do
    media_file_episode
    |> cast(attrs, [:media_file_id, :episode_id])
    |> validate_required([:media_file_id, :episode_id])
    |> foreign_key_constraint(:media_file_id)
    |> foreign_key_constraint(:episode_id)
    |> unique_constraint([:media_file_id, :episode_id],
      name: :media_file_episodes_media_file_id_episode_id_index
    )
  end
end
