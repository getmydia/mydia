defmodule Mydia.Plugins.PendingWrite do
  @moduledoc """
  A plugin page write waiting for the user to confirm it in the host's modal.
  `args` are host-resolved (ids already matched), so executing on approval never
  consults the plugin again. `description` is host-written text for the modal.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "plugin_pending_writes" do
    field :plugin_slug, :string
    field :session_id, :string
    field :op, :string
    field :surface, :string
    field :args, Mydia.Settings.JsonMapType
    field :description, :string
    field :expires_at, :utc_datetime
    belongs_to :user, Mydia.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(pending, attrs) do
    pending
    |> cast(attrs, [
      :plugin_slug,
      :user_id,
      :session_id,
      :op,
      :surface,
      :args,
      :description,
      :expires_at
    ])
    |> validate_required([
      :plugin_slug,
      :user_id,
      :session_id,
      :op,
      :surface,
      :args,
      :description,
      :expires_at
    ])
  end
end
