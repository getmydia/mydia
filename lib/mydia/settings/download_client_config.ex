defmodule Mydia.Settings.DownloadClientConfig do
  @moduledoc """
  Schema for download client configurations (qBittorrent, Transmission, HTTP).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @client_types [:qbittorrent, :transmission, :http]

  schema "download_client_configs" do
    field :name, :string
    field :type, Ecto.Enum, values: @client_types
    field :enabled, :boolean, default: true
    field :priority, :integer, default: 1
    field :host, :string
    field :port, :integer
    field :use_ssl, :boolean, default: false
    field :url_base, :string
    field :username, :string
    field :password, :string
    field :api_key, :string
    field :category, :string
    field :download_directory, :string
    field :connection_settings, :map

    belongs_to :updated_by, Mydia.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a download client config.
  """
  def changeset(download_client_config, attrs) do
    download_client_config
    |> cast(attrs, [
      :name,
      :type,
      :enabled,
      :priority,
      :host,
      :port,
      :use_ssl,
      :url_base,
      :username,
      :password,
      :api_key,
      :category,
      :download_directory,
      :connection_settings,
      :updated_by_id
    ])
    |> validate_required([:name, :type, :host, :port])
    |> validate_inclusion(:type, @client_types)
    |> validate_number(:port, greater_than: 0, less_than: 65536)
    |> validate_number(:priority, greater_than: 0)
    |> unique_constraint(:name)
  end
end
