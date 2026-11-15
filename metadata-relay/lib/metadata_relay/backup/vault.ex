defmodule MetadataRelay.Backup.Vault do
  @moduledoc """
  One backed-up group of players. `id` is random 128-bit lowercase hex.
  `lookup_hash` finds the vault from a recovery key, and `recovery_signer` and
  `recovery_envelope` (base64url) let a recovery key authenticate and unwrap
  the vault key. `epoch` rises when the vault key is rotated.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "backup_vaults" do
    field(:epoch, :integer)
    field(:lookup_hash, :string)
    field(:recovery_signer, :string)
    field(:recovery_envelope, :string)
    field(:last_write_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
