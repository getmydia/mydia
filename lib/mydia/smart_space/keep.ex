defmodule Mydia.SmartSpace.Keep do
  @moduledoc """
  A keep exempts a show, a season or an episode from Smart Space cleanup until
  someone removes it. Exactly one level per row: show (both nullable columns
  null), season (`season_number` set) or episode (`episode_id` set).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Mydia.Accounts.User
  alias Mydia.Media.{Episode, MediaItem}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "smart_space_keeps" do
    field :season_number, :integer

    belongs_to :media_item, MediaItem
    belongs_to :episode, Episode
    belongs_to :created_by, User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "Changeset for a keep; ids are set on the struct by the caller."
  def changeset(keep, attrs \\ %{}) do
    keep
    |> cast(attrs, [:season_number])
    |> validate_required([:media_item_id])
    |> validate_one_level()
    |> foreign_key_constraint(:media_item_id)
    |> foreign_key_constraint(:episode_id)
    |> unique_level_constraints()
  end

  # PostgreSQL reports the index name; SQLite reports the indexed columns
  # instead (`smart_space_keeps_<columns>_index`), so both spellings are listed.
  defp unique_level_constraints(changeset) do
    changeset
    |> unique_constraint(:media_item_id, name: :smart_space_keeps_show_index)
    |> unique_constraint(:media_item_id, name: :smart_space_keeps_media_item_id_index)
    |> unique_constraint(:season_number, name: :smart_space_keeps_season_index)
    |> unique_constraint(:season_number,
      name: :smart_space_keeps_media_item_id_season_number_index
    )
    |> unique_constraint(:episode_id, name: :smart_space_keeps_episode_index)
    |> unique_constraint(:episode_id, name: :smart_space_keeps_episode_id_index)
  end

  defp validate_one_level(changeset) do
    if get_field(changeset, :season_number) != nil and get_field(changeset, :episode_id) != nil do
      add_error(changeset, :episode_id, "cannot be set together with season_number")
    else
      changeset
    end
  end
end
