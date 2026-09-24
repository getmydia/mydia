defmodule Mydia.Accounts.RecoveryCode do
  @moduledoc """
  A single-use TOTP recovery code. Only the bcrypt hash of the normalized code
  (lowercase, no dash) is stored; `used_at` is set once when it is redeemed.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: binary(),
          user_id: binary(),
          code_hash: String.t(),
          used_at: DateTime.t() | nil,
          inserted_at: DateTime.t()
        }

  schema "user_recovery_codes" do
    field :code_hash, :string
    field :used_at, :utc_datetime

    belongs_to :user, Mydia.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
