defmodule Mydia.Settings.IndexerConfig do
  @moduledoc """
  Schema for indexer/search provider configurations (Prowlarr, Jackett, public indexers).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @indexer_types [:prowlarr, :jackett, :public]

  schema "indexer_configs" do
    field :name, :string
    field :type, Ecto.Enum, values: @indexer_types
    field :enabled, :boolean, default: true
    field :priority, :integer, default: 1
    field :base_url, :string
    field :api_key, :string
    field :indexer_ids, {:array, :string}
    field :categories, {:array, :string}
    field :rate_limit, :integer
    field :connection_settings, :map

    belongs_to :updated_by, Mydia.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating an indexer config.
  """
  def changeset(indexer_config, attrs) do
    indexer_config
    |> cast(attrs, [
      :name,
      :type,
      :enabled,
      :priority,
      :base_url,
      :api_key,
      :indexer_ids,
      :categories,
      :rate_limit,
      :connection_settings,
      :updated_by_id
    ])
    |> validate_required([:name, :type, :base_url])
    |> validate_inclusion(:type, @indexer_types)
    |> validate_number(:priority, greater_than: 0)
    |> validate_number(:rate_limit, greater_than: 0)
    |> unique_constraint(:name)
  end
end
