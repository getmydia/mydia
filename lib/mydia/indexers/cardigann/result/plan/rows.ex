defmodule Mydia.Indexers.Cardigann.Result.Plan.Rows do
  @moduledoc false
  # The compiled `search.rows` block. `after` and `count` are normalised to what
  # the row slicer needs (`after` defaults to 0, `count` stays nil when absent
  # or not a positive integer) so no adapter re-reads the raw definition.

  @type t :: %__MODULE__{
          selector: String.t(),
          attribute: String.t() | nil,
          after: non_neg_integer(),
          count: pos_integer() | nil,
          andmatch: boolean() | nil,
          missing_attribute_equals_no_results: boolean(),
          multiple: boolean(),
          filters: list()
        }

  defstruct selector: "",
            attribute: nil,
            after: 0,
            count: nil,
            andmatch: nil,
            missing_attribute_equals_no_results: false,
            multiple: false,
            filters: []
end
