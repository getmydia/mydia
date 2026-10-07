defmodule Mydia.Settings.StorageBackend do
  @moduledoc """
  An S3-compatible storage backend. Library paths reference it by name as
  `s3://<name>/<prefix>`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "storage_backends" do
    field :name, :string
    field :endpoint, :string
    field :region, :string, default: "us-east-1"
    field :bucket, :string
    field :access_key_id, :string
    field :secret_access_key, :string, redact: true
    field :path_style, :boolean, default: true

    belongs_to :updated_by, Mydia.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(backend, attrs) do
    backend
    |> cast(attrs, [
      :name,
      :endpoint,
      :region,
      :bucket,
      :access_key_id,
      :secret_access_key,
      :path_style,
      :updated_by_id
    ])
    |> validate_required([:name, :region, :bucket, :access_key_id, :secret_access_key])
    |> validate_name()
    |> validate_endpoint()
    |> unique_constraint(:name)
  end

  @doc """
  The name becomes the host part of `s3://<name>/...`. Shared with the env/YAML
  config schema so every source of backends is held to the same rules.
  """
  @spec validate_name(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_name(changeset) do
    changeset
    |> validate_format(:name, ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/,
      message: "use letters, digits, dot, dash or underscore"
    )
    |> validate_length(:name, max: 60)
  end

  @doc """
  An endpoint is a bare http(s)://host[:port]. Credentials in the URL
  (`user:pass@host`) are refused: keys have their own fields and a URL gets logged.
  """
  @spec validate_endpoint(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_endpoint(changeset) do
    validate_format(changeset, :endpoint, ~r{\Ahttps?://[^/\s@]+/?\z},
      message: "must be http(s)://host[:port]"
    )
  end

  @spec endpoint_url(t()) :: String.t()
  def endpoint_url(%__MODULE__{endpoint: endpoint, region: region}) do
    case endpoint do
      blank when blank in [nil, ""] -> "https://s3.#{region}.amazonaws.com"
      url -> String.trim_trailing(url, "/")
    end
  end
end
