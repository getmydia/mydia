defmodule Mydia.Accounts.IgnoredDiscoverTitle do
  @moduledoc """
  A title one user never wants to see while browsing Discover.

  Keyed on `(user_id, media_type, provider, provider_id)`. The media type is
  part of the key because TMDB numbers movies and TV separately, so the same id
  can name a movie and an unrelated show.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Mydia.Accounts.User

  @media_types ~w(movie tv_show)
  @providers ~w(tmdb tvdb)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "discover_ignored_titles" do
    belongs_to :user, User
    field :media_type, :string
    field :provider, :string
    field :provider_id, :integer

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "Validates the key fields. `user_id` is set by the caller, never cast."
  def changeset(ignored, attrs) do
    ignored
    |> cast(attrs, [:media_type, :provider, :provider_id])
    |> validate_required([:media_type, :provider, :provider_id])
    |> validate_inclusion(:media_type, @media_types)
    |> validate_inclusion(:provider, @providers)
    |> validate_number(:provider_id, greater_than: 0)
    |> unique_constraint([:user_id, :media_type, :provider, :provider_id],
      name: :discover_ignored_titles_user_id_media_type_provider_provider_id_index
    )
  end
end
