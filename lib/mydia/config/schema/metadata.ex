defmodule Mydia.Config.Schema.Metadata do
  @moduledoc """
  The `metadata` section of `Mydia.Config.Schema`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # Language sent to TMDB/TVDB through metadata-relay. Accepts ISO 639-1
    # codes ("de") or BCP 47 language tags ("de-DE", "pt-BR").
    field :language, :string, default: "en-US"
  end

  @type t :: %__MODULE__{}

  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:language])
    |> validate_required([:language])
    |> validate_length(:language, min: 2, max: 16)
  end
end
