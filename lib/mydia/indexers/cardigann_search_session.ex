defmodule Mydia.Indexers.CardigannSearchSession do
  @moduledoc """
  Schema for managing login sessions for private Cardigann indexers.

  Stores encrypted session cookies and expiration information to maintain
  authenticated sessions with indexers that require login.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: binary(),
          cookies: list() | nil,
          expires_at: DateTime.t() | nil,
          cardigann_definition:
            Mydia.Indexers.CardigannDefinition.t() | Ecto.Association.NotLoaded.t(),
          cardigann_definition_id: binary() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "cardigann_search_sessions" do
    field :cookies, Mydia.Settings.JsonListType
    field :expires_at, :utc_datetime

    belongs_to :cardigann_definition, Mydia.Indexers.CardigannDefinition

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a search session.
  """
  def changeset(session, attrs) do
    session
    |> cast(attrs, [:cookies, :expires_at, :cardigann_definition_id])
    |> validate_required([:cookies, :cardigann_definition_id])
    |> foreign_key_constraint(:cardigann_definition_id)
    |> unique_constraint(:cardigann_definition_id)
  end

  @doc """
  Returns true if the session has expired. A session without an expiry never does.
  """
  def expired?(%__MODULE__{expires_at: nil}), do: false

  def expired?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :gt
  end
end
