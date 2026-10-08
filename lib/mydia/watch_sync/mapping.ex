defmodule Mydia.WatchSync.Mapping do
  @moduledoc """
  Maps a local media item or episode to a remote provider id.

  User-independent: a remote id belongs to the server, not to a viewer.
  Keeping it separate stops N users storing N copies of the same rating key,
  and it is what removes the full-library crawl on every export.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: binary(),
          provider: String.t(),
          provider_instance_id: String.t(),
          remote_id: String.t(),
          last_seen_at: DateTime.t() | nil,
          media_item: Mydia.Media.MediaItem.t() | Ecto.Association.NotLoaded.t(),
          episode: Mydia.Media.Episode.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "remote_item_mappings" do
    field :provider, :string
    field :provider_instance_id, :string
    field :remote_id, :string
    field :last_seen_at, :utc_datetime

    belongs_to :media_item, Mydia.Media.MediaItem
    belongs_to :episode, Mydia.Media.Episode

    timestamps(type: :utc_datetime)
  end

  def changeset(mapping, attrs) do
    mapping
    |> cast(attrs, [
      :provider,
      :provider_instance_id,
      :media_item_id,
      :episode_id,
      :remote_id,
      :last_seen_at
    ])
    |> validate_required([:provider, :provider_instance_id, :remote_id])
    |> validate_one_parent()
    |> unique_copy_constraints()
    |> foreign_key_constraint(:media_item_id)
    |> foreign_key_constraint(:episode_id)
  end

  # Two names per index. Postgres reports the real index name on a violation;
  # SQLite reports only the columns, and ecto_sqlite3 guesses Ecto's
  # conventional "<table>_<cols>_index" name from them. Declaring both lets
  # either adapter resolve to the same changeset error. See priv/repo/README.md.
  @copy_index_names [
    :remote_item_mappings_movie_copy_index,
    :remote_item_mappings_provider_provider_instance_id_media_item_id_remote_id_index,
    :remote_item_mappings_episode_copy_index,
    :remote_item_mappings_provider_provider_instance_id_episode_id_remote_id_index
  ]

  defp unique_copy_constraints(changeset) do
    Enum.reduce(@copy_index_names, changeset, fn name, acc ->
      unique_constraint(acc, :remote_id,
        name: name,
        message: "already mapped to this remote item"
      )
    end)
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
