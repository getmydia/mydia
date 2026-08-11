defmodule Mydia.Sync.Run do
  @moduledoc """
  One recorded attempt to sync with an external provider.

  A `:skipped` run with a `skip_reason` is the point of this table. Before it,
  a sync that never ran and a sync that ran perfectly were indistinguishable
  in the database, the logs, and the UI.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:ok, :error, :skipped]
  @directions [:import, :export, :bidirectional]

  @type t :: %__MODULE__{
          id: binary(),
          provider: String.t(),
          provider_instance_id: String.t(),
          user_id: binary() | nil,
          direction: atom() | nil,
          status: atom(),
          skip_reason: String.t() | nil,
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          counts: map(),
          error: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "sync_runs" do
    field :provider, :string
    field :provider_instance_id, :string
    field :direction, Ecto.Enum, values: @directions
    field :status, Ecto.Enum, values: @statuses
    field :skip_reason, :string
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :counts, Mydia.Settings.JsonMapType, default: %{}
    field :error, :string

    belongs_to :user, Mydia.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :provider,
      :provider_instance_id,
      :user_id,
      :direction,
      :status,
      :skip_reason,
      :started_at,
      :finished_at,
      :counts,
      :error
    ])
    |> validate_required([:provider, :provider_instance_id, :status])
    |> validate_inclusion(:status, @statuses)
    |> stringify_counts()
  end

  # Callers build counts with atom keys (`%{imported: 3}`), but the column round
  # trips through Jason, so a reloaded row comes back string-keyed. Without
  # normalizing here, the same field would be atom-keyed on the struct returned
  # by an insert and string-keyed on the next read, and consumers like the admin
  # run summary would work or break depending on which one they happened to get.
  defp stringify_counts(changeset) do
    case fetch_change(changeset, :counts) do
      {:ok, counts} when is_map(counts) ->
        put_change(changeset, :counts, Map.new(counts, fn {k, v} -> {to_string(k), v} end))

      _ ->
        changeset
    end
  end

  def statuses, do: @statuses
end
