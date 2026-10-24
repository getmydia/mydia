defmodule Mydia.Config.Schema.Ui do
  @moduledoc """
  The `ui` section of `Mydia.Config.Schema`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # Interface language for requests whose user and browser name no
    # translated locale. A gettext code (`es`, `pt_BR`); an untranslated code
    # is accepted here and skipped by Mydia.Locale.resolve/4, so a YAML value
    # naming a language whose translation was dropped never blocks boot.
    field :default_locale, :string, default: "en"
  end

  @type t :: %__MODULE__{}

  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:default_locale])
    |> validate_required([:default_locale])
    |> validate_length(:default_locale, min: 2, max: 16)
  end
end
