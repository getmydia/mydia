defmodule Mydia.Plugins.JournalEntry do
  @moduledoc """
  One executed plugin write, with what is needed to undo it. `status` is
  `applied`, `undone`, `conflict` (the state changed since, so undo refused to
  overwrite it) or `irreversible`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(applied undone conflict irreversible)

  @type t :: %__MODULE__{}

  schema "plugin_write_journal" do
    field :plugin_slug, :string
    field :op, :string
    field :surface, :string
    field :args, Mydia.Settings.JsonMapType
    field :result, Mydia.Settings.JsonMapType
    field :inverse, Mydia.Settings.JsonMapType
    field :description, :string
    field :batch_id, :string
    field :status, :string
    belongs_to :user, Mydia.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :plugin_slug,
      :user_id,
      :op,
      :surface,
      :args,
      :result,
      :inverse,
      :description,
      :batch_id,
      :status
    ])
    |> validate_required([
      :plugin_slug,
      :user_id,
      :op,
      :surface,
      :args,
      :result,
      :description,
      :batch_id,
      :status
    ])
    |> validate_inclusion(:status, @statuses)
  end
end
