defmodule Mydia.Config.Schema.Logging do
  @moduledoc """
  The `logging` section of `Mydia.Config.Schema`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :level, :string, default: "info"
    field :format, :string, default: "[$level] $message\n"
  end

  @type t :: %__MODULE__{}

  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:level, :format])
    |> validate_required([:level])
    |> validate_inclusion(:level, ["debug", "info", "warning", "error"])
  end
end
