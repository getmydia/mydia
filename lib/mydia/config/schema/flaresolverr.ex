defmodule Mydia.Config.Schema.FlareSolverr do
  @moduledoc """
  The `flaresolverr` section of `Mydia.Config.Schema`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :enabled, :boolean, default: false
    field :url, :string
    field :timeout, :integer, default: 60_000
    field :max_timeout, :integer, default: 120_000
    # Why the default is 1: see "Concurrency" in Mydia.Indexers.FlareSolverr.
    field :max_concurrent_requests, :integer, default: 1
  end

  @type t :: %__MODULE__{}

  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:enabled, :url, :timeout, :max_timeout, :max_concurrent_requests])
    |> validate_url()
    |> validate_number(:timeout, greater_than: 0)
    |> validate_number(:max_timeout, greater_than: 0)
    |> validate_number(:max_concurrent_requests, greater_than: 0)
  end

  defp validate_url(changeset) do
    enabled = get_field(changeset, :enabled)
    url = get_field(changeset, :url)

    if enabled && (is_nil(url) || url == "") do
      add_error(changeset, :url, "is required when FlareSolverr is enabled")
    else
      changeset
    end
  end
end
