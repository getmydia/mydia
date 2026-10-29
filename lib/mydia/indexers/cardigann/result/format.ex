defmodule Mydia.Indexers.Cardigann.Result.Format do
  @moduledoc false
  # What a response format (HTML, JSON, XML) has to provide so the shared field
  # extractor can drive it. An adapter parses a body once, lists its rows and
  # reads one field's raw string from a row; filters, defaults, text fields and
  # `after`/`count` slicing live outside the adapters.
  #
  # `raw/4` and `case_value/4` take an `opts` keyword. `:context` is the
  # template context to render a still-templated selector, case key or remove
  # selector against. The plan leaves anything that reads `.Result` raw because
  # it can only be rendered per row, and an adapter has no result context of its
  # own, so the extractor passes it here. Without `:context`, selectors are used
  # as the plan holds them.
  #
  # `Plan.Field.case` is ordered with the `*` default last, so `case_value/4`
  # takes the first match in list order.

  alias Mydia.Indexers.Cardigann.Result.Plan
  alias Mydia.Indexers.Cardigann.Result.Plan.{Field, Rows}

  @type doc :: term()
  @type row :: term()
  @type value :: {:ok, String.t()} | :not_found

  @callback document(body :: binary(), Plan.t()) :: {:ok, doc} | {:error, term()}
  @callback rows(doc, Rows.t()) :: [row]
  @callback raw(doc, row, Field.t(), keyword()) :: value
  @callback case_value(doc, row, Field.t(), keyword()) :: value
end
