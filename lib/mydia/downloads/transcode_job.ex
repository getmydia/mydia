defmodule Mydia.Downloads.TranscodeJob do
  @moduledoc """
  Schema for tracking transcode jobs and cached transcoded files.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: binary(),
          type: String.t(),
          resolution: String.t() | nil,
          status: String.t() | nil,
          progress: float() | nil,
          output_path: String.t() | nil,
          file_size: integer() | nil,
          error: String.t() | nil,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          last_accessed_at: DateTime.t() | nil,
          media_file: Mydia.Library.MediaFile.t() | Ecto.Association.NotLoaded.t(),
          user: Mydia.Accounts.User.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "transcode_jobs" do
    field :type, :string, default: "download"
    field :resolution, :string
    field :status, :string
    field :progress, :float
    field :output_path, :string
    field :file_size, :integer
    field :error, :string
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :last_accessed_at, :utc_datetime

    belongs_to :media_file, Mydia.Library.MediaFile
    belongs_to :user, Mydia.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @valid_statuses ~w(pending transcoding playing ready failed)
  @valid_resolutions ~w(original 1080p 720p 480p)
  @valid_types ~w(download stream direct remux)

  @doc """
  Changeset for creating or updating a transcode job.
  """
  def changeset(transcode_job, attrs) do
    transcode_job
    |> cast(attrs, [
      :media_file_id,
      :user_id,
      :type,
      :resolution,
      :status,
      :progress,
      :output_path,
      :file_size,
      :error,
      :started_at,
      :completed_at,
      :last_accessed_at
    ])
    |> validate_required([:media_file_id, :type, :status])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:type, @valid_types)
    |> validate_inclusion(:resolution, @valid_resolutions)
    |> validate_number(:progress, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:file_size, greater_than: 0)
    |> foreign_key_constraint(:media_file_id)
    # Conditional unique constraint is handled by the partial index in the database
    # but we can try to enforce it here for downloads if we want,
    # though Ecto unique_constraint usually maps to a specific index name.
    # Since the index name for the partial index is likely the same as the old one (or auto-generated),
    # we'll keep the constraint check but it might need to be scoped if Ecto supported 'where' in unique_constraint (it doesn't directly).
    # For now, we rely on the DB raising if we violate the partial index for downloads.
    |> unique_constraint([:media_file_id, :resolution],
      name: :transcode_jobs_media_file_id_resolution_index,
      message: "transcode job already exists for this file and resolution"
    )
  end
end
