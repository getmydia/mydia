defmodule Mydia.Settings.LibraryPath do
  @moduledoc """
  Schema for library paths that should be monitored for media files.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @path_types [:movies, :series, :mixed]
  @scan_statuses [:success, :failed, :in_progress]

  schema "library_paths" do
    field :path, :string
    field :type, Ecto.Enum, values: @path_types
    field :monitored, :boolean, default: true
    field :scan_interval, :integer, default: 3600
    field :last_scan_at, :utc_datetime
    field :last_scan_status, Ecto.Enum, values: @scan_statuses
    field :last_scan_error, :string

    belongs_to :quality_profile, Mydia.Settings.QualityProfile
    belongs_to :updated_by, Mydia.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a library path.
  """
  def changeset(library_path, attrs) do
    library_path
    |> cast(attrs, [
      :path,
      :type,
      :monitored,
      :scan_interval,
      :last_scan_at,
      :last_scan_status,
      :last_scan_error,
      :quality_profile_id,
      :updated_by_id
    ])
    |> validate_required([:path, :type])
    |> validate_inclusion(:type, @path_types)
    |> validate_number(:scan_interval, greater_than: 0)
    |> unique_constraint(:path)
  end
end
