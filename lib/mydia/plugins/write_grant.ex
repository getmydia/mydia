defmodule Mydia.Plugins.WriteGrant do
  @moduledoc """
  A user's standing permission for one plugin to perform writes on one surface
  without asking. `scope` is `"session"` (valid for one page session id) or
  `"always"` (session_id is "").
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "plugin_write_grants" do
    field :plugin_slug, :string
    field :surface, :string
    field :scope, :string
    field :session_id, :string, default: ""
    belongs_to :user, Mydia.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [:plugin_slug, :user_id, :surface, :scope, :session_id])
    |> validate_required([:plugin_slug, :user_id, :surface, :scope])
    |> validate_inclusion(:scope, ~w(session always))
    |> unique_constraint([:plugin_slug, :user_id, :surface, :scope, :session_id])
  end
end
