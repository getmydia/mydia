defmodule MetadataRelay.Backup.Member do
  @moduledoc """
  A player allowed to write to a vault: its Ed25519 `signer` public key
  (base64url), the `slot_id` it owns, and the vault key `envelope` sealed to
  it (base64url).
  """

  use Ecto.Schema

  @primary_key false

  schema "backup_members" do
    field(:vault_id, :string)
    field(:signer, :string)
    field(:slot_id, :string)
    field(:envelope, :string)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}
end
