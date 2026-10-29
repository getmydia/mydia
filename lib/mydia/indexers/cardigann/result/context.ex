defmodule Mydia.Indexers.Cardigann.Result.Context do
  @moduledoc false
  # What one parse call knows beyond the plan and the body: who is searching,
  # the template context, where relative links resolve and how site categories
  # map. `search` is the definition's raw search block, kept for
  # `JsonPath.reports_no_results?/2`, which reads a JSON `rows.count` selector
  # the plan does not compile.

  @type t :: %__MODULE__{
          indexer_name: String.t(),
          template_context: map(),
          base_url: String.t(),
          category_mappings: list(),
          search: map()
        }

  defstruct indexer_name: "",
            template_context: %{},
            base_url: "",
            category_mappings: [],
            search: %{}
end
