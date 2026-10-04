defmodule Mydia.Plugins.ShelfItem do
  @moduledoc """
  One verified title on a shelf. Title, year and poster are cached from the
  verification fetch so the rail renders without a relay round trip.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "plugin_shelf_items" do
    belongs_to :shelf, Mydia.Plugins.Shelf
    field :position, :integer
    field :media_type, Ecto.Enum, values: [:movie, :tv_show]
    field :provider, Ecto.Enum, values: [:tmdb, :tvdb]
    field :provider_id, :integer
    field :reason, :string
    field :title, :string
    field :year, :integer
    field :poster_path, :string

    timestamps(type: :utc_datetime_usec)
  end
end
