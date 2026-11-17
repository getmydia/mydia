defmodule Mydia.Config.Schema.Oban do
  @moduledoc """
  The `oban` section of `Mydia.Config.Schema`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :poll_interval, :integer, default: 1000
    field :max_age_days, :integer, default: 7
  end

  @type t :: %__MODULE__{}

  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:poll_interval, :max_age_days])
    |> validate_number(:poll_interval, greater_than: 0)
    |> validate_number(:max_age_days, greater_than: 0)
  end
end
