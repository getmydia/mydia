defmodule Mydia.Accounts.AccessRestriction do
  @moduledoc """
  Per-account limits on which media a user may see.

  Both fields are independently optional. `allowed_categories` of `nil` or `[]`
  means no category limit, and `max_content_age` of `nil` means no rating
  limit, so a row can restrict one dimension without touching the other.

  A `nil` rating limit and a limit of 18 are not the same thing. No limit shows
  everything including unrated titles; any set limit hides unrated titles,
  because an unknown rating is not evidence that a title is suitable.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Mydia.Media.ContentRating
  alias Mydia.Media.MediaCategory

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: binary(),
          user_id: binary(),
          allowed_categories: [String.t()] | nil,
          max_content_age: integer() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "user_access_restrictions" do
    field :allowed_categories, {:array, :string}
    field :max_content_age, :integer

    belongs_to :user, Mydia.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for an access restriction. `user_id` is set programmatically and is
  deliberately absent from the cast.
  """
  def changeset(restriction, attrs) do
    restriction
    |> cast(attrs, [:allowed_categories, :max_content_age])
    |> validate_categories()
    |> validate_inclusion(:max_content_age, valid_ages(),
      message: "must be one of the offered age limits"
    )
    |> unique_constraint(:user_id)
  end

  defp validate_categories(changeset) do
    validate_change(changeset, :allowed_categories, fn :allowed_categories, categories ->
      valid = Enum.map(MediaCategory.all(), &to_string/1)

      case Enum.reject(categories, &(&1 in valid)) do
        [] -> []
        bad -> [allowed_categories: "contains unknown categories: #{Enum.join(bad, ", ")}"]
      end
    end)
  end

  defp valid_ages, do: Enum.map(ContentRating.thresholds(), fn {_label, age} -> age end)
end
