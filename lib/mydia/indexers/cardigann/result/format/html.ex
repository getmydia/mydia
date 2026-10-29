defmodule Mydia.Indexers.Cardigann.Result.Format.Html do
  @moduledoc false
  # HTML adapter: lexbor documents, CSS selectors with `:contains()` support.
  # Behaviour is a port of the HTML helpers in `CardigannResultParser`.

  @behaviour Mydia.Indexers.Cardigann.Result.Format

  require Logger

  alias Mydia.Indexers.Cardigann.Charset
  alias Mydia.Indexers.Cardigann.Result.Plan
  alias Mydia.Indexers.Cardigann.Result.Plan.Rows
  alias Mydia.Indexers.Cardigann.Selector
  alias Mydia.Indexers.CardigannTemplate

  @impl true
  def document(body, %Plan{} = plan) do
    converted = Charset.decode(body, plan.encoding)
    {:ok, Selector.parse(converted, declared_selectors(plan))}
  rescue
    error -> {:error, error}
  end

  @impl true
  def rows(document, %Rows{selector: selector} = rows) do
    found = Selector.find(document, :root, selector)
    Logger.info("Found #{length(found)} rows before filtering")

    # `multiple` needs no handling: the selector engine already unions the
    # comma-separated alternatives.
    if rows.missing_attribute_equals_no_results and is_binary(rows.attribute) do
      Enum.filter(found, fn row -> Selector.attribute([row], rows.attribute) != nil end)
    else
      found
    end
  end

  @impl true
  def raw(document, row, field, opts \\ []) do
    row = without_removed(document, row, field.remove, opts)
    selector = render(field.selector, opts)

    case field.attribute do
      nil ->
        case Selector.find(document, row, selector) do
          [] -> :not_found
          elements -> {:ok, elements |> Selector.text() |> String.trim()}
        end

      attribute ->
        case document |> Selector.find(row, selector) |> Selector.attribute(attribute) do
          nil -> :not_found
          value -> {:ok, String.trim(value)}
        end
    end
  end

  # `case` maps a CSS selector to a literal value, scoped to whatever the field's
  # own selector matched. The plan orders `*` last, so it is the fallback.
  @impl true
  def case_value(document, row, field, opts \\ []) do
    row = without_removed(document, row, field.remove, opts)

    scope =
      case render(field.selector, opts) do
        sel when sel in [nil, ""] -> [row]
        sel -> Selector.find(document, row, sel)
      end

    if scope == [] do
      :not_found
    else
      field.case
      |> Enum.find_value(fn {key, value} ->
        if matches?(document, scope, render(key, opts)), do: value
      end)
      |> case do
        nil -> :not_found
        value -> {:ok, value}
      end
    end
  end

  defp matches?(_document, _scope, "*"), do: true

  defp matches?(document, scope, selector),
    do: Enum.any?(scope, &(Selector.find(document, &1, selector) != []))

  defp without_removed(_document, row, nil, _opts), do: row

  defp without_removed(document, row, remove, opts),
    do: Selector.without(document, row, Enum.map(remove, &render(&1, opts)))

  # Every selector the plan may evaluate, so Selector.parse/2 marks each
  # :contains() needle once.
  defp declared_selectors(%Plan{} = plan) do
    fields = plan.selector_fields ++ plan.text_fields

    field_selectors =
      Enum.flat_map(fields, fn field ->
        [field.selector | Enum.map(field.case || [], &elem(&1, 0)) ++ (field.remove || [])]
      end)

    [plan.rows.selector | field_selectors] |> Enum.reject(&is_nil/1) |> Enum.map(&to_string/1)
  end

  defp render(selector, opts) when is_binary(selector) do
    context = Keyword.get(opts, :context, %{})

    if map_size(context) > 0 and String.contains?(selector, "{{") do
      case CardigannTemplate.render(selector, context, url_encode: false) do
        {:ok, rendered} -> rendered
        {:error, _} -> selector
      end
    else
      selector
    end
  end

  defp render(selector, _opts), do: selector
end
