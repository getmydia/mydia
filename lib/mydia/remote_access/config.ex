defmodule Mydia.RemoteAccess.Config do
  @moduledoc """
  Schema for remote access instance configuration.
  Stores the instance identity for remote access.

  Note: The relay URL is read from the METADATA_RELAY_URL environment variable
  at runtime via `Mydia.Metadata.metadata_relay_url/0`, not stored in the database.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: binary(),
          instance_id: String.t() | nil,
          enabled: boolean(),
          direct_urls: [String.t()],
          cert_fingerprint: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "remote_access_config" do
    field :instance_id, :string
    field :enabled, :boolean, default: false
    field :direct_urls, {:array, :string}, default: []
    field :cert_fingerprint, :string

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating remote access configuration.
  """
  def changeset(config, attrs) do
    config
    |> cast(attrs, [
      :instance_id,
      :enabled,
      :direct_urls,
      :cert_fingerprint
    ])
    |> validate_required([:instance_id])
    |> validate_length(:instance_id, min: 1, max: 255)
    |> unique_constraint(:instance_id)
  end

  @doc """
  Changeset for toggling remote access enabled state.
  """
  def toggle_enabled_changeset(config, enabled) when is_boolean(enabled) do
    change(config, enabled: enabled)
  end

  @doc """
  Changeset for updating direct URLs.
  """
  def update_direct_urls_changeset(config, direct_urls) do
    change(config, direct_urls: direct_urls)
  end
end
