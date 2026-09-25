defmodule Mydia.Accounts.Passkey do
  @moduledoc """
  A WebAuthn passkey registered to a user.

  `credential_id` is the base64url credential ID exactly as the browser reports
  it in `PublicKeyCredential.id`. `public_key` is the COSE key map returned by
  `wax_`, stored with `:erlang.term_to_binary/1` and read back with `[:safe]`.
  `rp_id` is the host the passkey was registered on; the browser will only
  offer it there.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @default_name "Passkey"
  @server_fields [:credential_id, :rp_id, :sign_count, :aaguid]

  @type t :: %__MODULE__{}

  schema "user_passkeys" do
    field :credential_id, :string
    field :public_key, :binary, redact: true
    field :rp_id, :string
    field :sign_count, :integer, default: 0
    field :aaguid, :string
    field :transports, :string, default: "[]"
    field :name, :string
    field :last_used_at, :utc_datetime

    belongs_to :user, Mydia.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a new passkey from a verified registration. Everything except `name`
  comes from the server's own verification, so it is set with `change/2`, not
  cast.
  """
  def create_changeset(%__MODULE__{} = passkey, attrs) do
    passkey
    |> change(Map.take(attrs, @server_fields))
    |> put_change(:public_key, :erlang.term_to_binary(Map.fetch!(attrs, :public_key)))
    |> put_change(:transports, Jason.encode!(Map.get(attrs, :transports, [])))
    |> put_change(:name, normalize_name(Map.get(attrs, :name)))
    |> validate_required([:credential_id, :public_key, :rp_id, :name])
    |> validate_length(:name, max: 100)
    |> unique_constraint(:credential_id)
  end

  @doc """
  Renames a passkey. The name is user input: trimmed, required, 1 to 100 characters.
  """
  def rename_changeset(%__MODULE__{} = passkey, attrs) do
    passkey
    |> cast(attrs, [:name])
    |> update_change(:name, fn name -> if is_binary(name), do: String.trim(name), else: name end)
    |> validate_required([:name])
    |> validate_length(:name, max: 100)
  end

  @spec cose_key(t()) :: map()
  def cose_key(%__MODULE__{public_key: bin}) when is_binary(bin) do
    case :erlang.binary_to_term(bin, [:safe]) do
      %{} = key -> key
      _ -> %{}
    end
  rescue
    ArgumentError -> %{}
  end

  def cose_key(_passkey), do: %{}

  @spec transports(t()) :: [String.t()]
  def transports(%__MODULE__{transports: json}) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> []
    end
  end

  def transports(_passkey), do: []

  defp normalize_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> @default_name
      trimmed -> trimmed
    end
  end

  defp normalize_name(_name), do: @default_name
end
