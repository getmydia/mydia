defmodule MetadataRelay.UpdateCheck.Record do
  @moduledoc """
  One install's update check for one ISO week. See `MetadataRelay.UpdateCheck`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  @dbs ["sqlite", "postgres"]

  schema "update_checks" do
    field(:install_id, :string)
    field(:week, :date)
    field(:version, :string)
    field(:arch, :string)
    field(:db, :string)
    field(:checked_at, :utc_datetime)
  end

  @doc """
  Validates what a Mydia install sends. Every field is required and tightly
  shaped, so nothing free-form (a hostname, a path, a username) can ride along
  in one of them.
  """
  def changeset(record, attrs) do
    record
    |> cast(attrs, [:install_id, :week, :version, :arch, :db, :checked_at])
    |> validate_required([:install_id, :week, :version, :arch, :db, :checked_at])
    |> validate_format(:install_id, ~r/\A[0-9a-f]{64}\z/)
    |> validate_length(:version, max: 64)
    |> validate_change(:version, fn :version, version ->
      case Version.parse(version) do
        {:ok, _} -> []
        :error -> [version: "is not a semantic version"]
      end
    end)
    |> validate_format(:arch, ~r/\A[A-Za-z0-9_.\-]{1,64}\z/)
    |> validate_inclusion(:db, @dbs)
  end
end
