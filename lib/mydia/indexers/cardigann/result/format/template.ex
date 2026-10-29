defmodule Mydia.Indexers.Cardigann.Result.Format.Template do
  @moduledoc false
  # Renders a selector, case key or remove selector that the plan left templated
  # because it reads `.Result`. Shared by every adapter so they agree on when a
  # string is rendered (only with a non-empty `:context` and a `{{`) and on the
  # fallback (a template that fails to render is used as written).

  alias Mydia.Indexers.CardigannTemplate

  @spec render(term(), keyword()) :: term()
  def render(selector, opts) when is_binary(selector) do
    context = Keyword.get(opts, :context, %{})

    # Plan.compile already rendered every template that does not read
    # `.Result`; rendering its output again would evaluate any template syntax
    # a keyword or setting carried.
    if map_size(context) > 0 and String.contains?(selector, "{{") and
         String.contains?(selector, ".Result") do
      case CardigannTemplate.render(selector, context, url_encode: false) do
        {:ok, rendered} -> rendered
        {:error, _} -> selector
      end
    else
      selector
    end
  end

  def render(selector, _opts), do: selector
end
