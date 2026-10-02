defmodule Mydia.Plugins.ShelfDismissal do
  @moduledoc """
  A title a user said they are not interested in, for one plugin shelf. Fed
  back to the plugin as `exclude` and enforced again by the verifier.
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

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
