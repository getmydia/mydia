defmodule Mydia.Media.Episode do
  @moduledoc """
  Schema for TV show episodes.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: binary(),
          season_number: integer() | nil,
          episode_number: integer() | nil,
          title: String.t() | nil,
          air_date: Date.t() | nil,
          metadata: map() | nil,
          monitored: boolean(),
          last_upgrade_check_at: DateTime.t() | nil,
          media_item: Mydia.Media.MediaItem.t() | Ecto.Association.NotLoaded.t(),
          media_files: [Mydia.Library.MediaFile.t()] | Ecto.Association.NotLoaded.t(),
          downloads: [Mydia.Downloads.Download.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "episodes" do
    field :season_number, :integer
    field :episode_number, :integer
    field :title, :string
    field :air_date, :date
    field :metadata, Mydia.Media.EpisodeDataType
    field :monitored, :boolean, default: true
    # Set programmatically by the upgrade sweep; never cast from user input.
    field :last_upgrade_check_at, :utc_datetime

    belongs_to :media_item, Mydia.Media.MediaItem
    has_many :media_files, Mydia.Library.MediaFile
    has_many :downloads, Mydia.Downloads.Download

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating an episode.
  """
  def changeset(episode, attrs) do
    episode
    |> cast(attrs, [
      :media_item_id,
      :season_number,
      :episode_number,
      :title,
      :air_date,
      :metadata,
      :monitored
    ])
    |> validate_required([:media_item_id, :season_number, :episode_number])
    |> validate_number(:season_number, greater_than_or_equal_to: 0)
    |> validate_number(:episode_number, greater_than: 0)
    |> foreign_key_constraint(:media_item_id)
    |> unique_constraint([:media_item_id, :season_number, :episode_number],
      name: :episodes_media_item_id_season_number_episode_number_index
    )
  end
end
