defmodule Mydia.Indexers.Cardigann.Result.Plan.Field do
  @moduledoc false
  # One compiled `search.fields` entry. A field is either selector-based or
  # computed from `text`; `text` holds any scalar `text:` as a string, so a YAML
  # integer (`text: 1`) is a text field like any other.

  @type t :: %__MODULE__{
          name: String.t(),
          selector: String.t() | nil,
          attribute: String.t() | nil,
          filters: list(),
          remove: [String.t()] | nil,
          case: [{String.t(), String.t()}] | nil,
          optional: boolean(),
          default: term(),
          text: String.t() | nil
        }

  defstruct [
    :name,
    :selector,
    :attribute,
    :remove,
    :case,
    :default,
    :text,
    filters: [],
    optional: false
  ]
end
