defmodule Mydia.Library.ImportRun do
  @moduledoc """
  A single user-started import of a library path.

  Runs are kept as history. They are cheap, one row per press of Start, and
  they are the only place Stop needs to write: the coordinator re-reads its own
  row between chunks and drains when it sees `:stopping`.

  There is no resume cursor on this row on purpose. Every unit of work the
  coordinator does is committed as it completes, so a later run rediscovers
  exactly the outstanding work by querying for it. See the design spec.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Mydia.Accounts.User
  alias Mydia.Settings.LibraryPath

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @modes ~w(review unattended)a
  @statuses ~w(running stopping stopped done failed)a
  @phases ~w(scanning matching finished)a

  @active_statuses ~w(running stopping)a

  @type t :: %__MODULE__{
          id: binary(),
          library_path_id: binary(),
          user_id: binary() | nil,
          mode: :review | :unattended,
          status: :running | :stopping | :stopped | :done | :failed,
          phase: :scanning | :matching | :finished,
          files_discovered: integer(),
          files_matched: integer(),
          files_linked: integer(),
          current_file: String.t() | nil,
          error: String.t() | nil,
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil
        }

  schema "import_runs" do
    field :mode, Ecto.Enum, values: @modes, default: :review
    field :status, Ecto.Enum, values: @statuses, default: :running
    field :phase, Ecto.Enum, values: @phases, default: :scanning

    field :files_discovered, :integer, default: 0
    field :files_matched, :integer, default: 0
    field :files_linked, :integer, default: 0

    field :current_file, :string
    field :error, :string
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    belongs_to :library_path, LibraryPath
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Statuses that mean the coordinator may still be working.
  """
  def active_statuses, do: @active_statuses

  @doc """
  Builds a changeset for a new run.
  """
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:library_path_id, :user_id, :mode])
    |> validate_required([:library_path_id, :mode])
    |> put_change(:status, :running)
    |> put_change(:phase, :scanning)
    |> put_change(:started_at, DateTime.utc_now() |> DateTime.truncate(:second))
    |> foreign_key_constraint(:library_path_id)
    |> guard_single_active_run()
  end

  @doc """
  Builds a changeset for progress and lifecycle updates.
  """
  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :status,
      :phase,
      :files_discovered,
      :files_matched,
      :files_linked,
      :current_file,
      :error
    ])
    |> maybe_set_finished_at()
    |> guard_single_active_run()
  end

  # Two names for one guarantee: on Postgres the constraint violation reports
  # the real index name. SQLite's driver never gets an index name back from a
  # partial-unique violation (just "UNIQUE constraint failed: <table>.<col>"),
  # so ecto_sqlite3 guesses "<table>_<col>_index" instead. Declaring both lets
  # either adapter's error resolve to the same changeset error. Kept as one
  # shared function so the two names never drift out of sync between
  # create_changeset/1 and changeset/2.
  defp guard_single_active_run(changeset) do
    changeset
    |> unique_constraint(:library_path_id,
      name: :import_runs_one_active_per_library_path,
      message: "already has a running import"
    )
    |> unique_constraint(:library_path_id,
      name: :import_runs_library_path_id_index,
      message: "already has a running import"
    )
  end

  defp maybe_set_finished_at(changeset) do
    case get_change(changeset, :status) do
      status when status in [:stopped, :done, :failed] ->
        put_change(changeset, :finished_at, DateTime.utc_now() |> DateTime.truncate(:second))

      _ ->
        changeset
    end
  end
end
