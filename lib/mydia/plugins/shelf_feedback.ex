defmodule Mydia.Plugins.ShelfFeedback do
  @moduledoc """
  A user's rating of a title on one plugin shelf: `:down` hides it, `:up` hides
  it and tells the plugin the user liked it (`via: :seen`) or added it from the
  shelf (`via: :added`). Fed back to the plugin as `exclude` and `feedback`, and
  enforced again by the verifier.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "plugin_shelf_dismissals" do
    field :plugin_slug, :string
    field :shelf_key, :string
    field :user_id, :binary_id
    field :media_type, Ecto.Enum, values: [:movie, :tv_show]
    field :provider, Ecto.Enum, values: [:tmdb, :tvdb]
    field :provider_id, :integer
    field :rating, Ecto.Enum, values: [:up, :down], default: :down
    field :via, Ecto.Enum, values: [:added, :seen]
    field :title, :string
    field :year, :integer

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
