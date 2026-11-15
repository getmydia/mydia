defmodule MetadataRelay.Backup.Slot do
  @moduledoc """
  The current ciphertext of one member's slot. `path` is relative to
  `backup.dir`; `seq` rises with every write and `size` is the file's bytes.
  """

  use Ecto.Schema

  @primary_key false

  schema "backup_slots" do
    field(:vault_id, :string)
    field(:slot_id, :string)
    field(:seq, :integer)
    field(:epoch, :integer)
    field(:size, :integer)
    field(:path, :string)
    field(:updated_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
