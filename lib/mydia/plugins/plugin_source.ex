defmodule Mydia.Plugins.PluginSource do
  @moduledoc """
  A third-party plugin catalog with the minisign key pinned when it was added.
  `declared` rows come from env/YAML (`Mydia.Plugins.DeclaredSources`) and are
  read-only in the UI. `key_id` is the fingerprint, derived from `public_key`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Mydia.Plugins.Index.Signature

  @primary_key {:id, :binary_id, autogenerate: true}

  @type t :: %__MODULE__{}

  schema "plugin_sources" do
    field :url, :string
    field :name, :string
    field :public_key, :string
    field :key_id, :string
    field :declared, :boolean, default: false
    field :enabled, :boolean, default: true
    field :last_error, :string
    field :last_fetched_at, :utc_datetime_usec
    field :plugin_count, :integer

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(source, attrs) do
    source
    |> cast(attrs, [:url, :name, :public_key, :enabled])
    |> update_change(:url, &String.trim/1)
    |> validate_required([:url, :public_key])
    |> validate_change(:url, fn :url, url ->
      if URI.parse(url).scheme == "https", do: [], else: [url: "must be an https URL"]
    end)
    |> put_key_id()
    |> unique_constraint(:url)
  end

  def status_changeset(source, attrs) do
    cast(source, attrs, [:name, :last_error, :last_fetched_at, :plugin_count])
  end

  defp put_key_id(changeset) do
    case get_field(changeset, :public_key) do
      nil ->
        changeset

      key ->
        case Signature.parse_public_key(key) do
          {:ok, parsed} ->
            changeset
            |> put_change(:public_key, parsed.encoded)
            |> put_change(:key_id, Signature.fingerprint(parsed))

          {:error, _} ->
            add_error(changeset, :public_key, "is not a minisign public key")
        end
    end
  end
end
