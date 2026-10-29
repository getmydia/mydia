defmodule Mydia.Indexers.Cardigann.Result.Plan do
  @moduledoc false
  # A definition's `search.rows` and `search.fields` compiled once per search
  # into structs the format adapters and the shared field extractor read, so
  # nothing re-interprets raw definition maps per row. Keys are normalised here
  # (atom or string), scalar `text:` becomes a string, and templates that do not
  # depend on a row's `.Result` are rendered a single time.

  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.Cardigann.Result.Plan.{Field, ResponseType, Rows}
  alias Mydia.Indexers.Cardigann.TextFields
  alias Mydia.Indexers.CardigannDefinition.Parsed
  alias Mydia.Indexers.CardigannTemplate

  @type t :: %__MODULE__{
          format: :html | :json | :xml | nil,
          encoding: String.t() | nil,
          rows: Rows.t(),
          selector_fields: [Field.t()],
          text_fields: [Field.t()]
        }

  defstruct [:format, :encoding, :rows, selector_fields: [], text_fields: []]

  @spec compile(Parsed.t(), map(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def compile(%Parsed{} = definition, template_context, opts \\ []) do
    search = definition.search || %{}
    context = template_context || %{}

    with {:ok, rows} <- compile_rows(fetch(search, :rows), context),
         {:ok, fields} <- compile_fields(fetch(search, :fields) || %{}, context) do
      {text_fields, selector_fields} = Enum.split_with(fields, &(&1.text != nil))

      {:ok,
       %__MODULE__{
         format: ResponseType.declared(definition, opts),
         encoding: definition.encoding,
         rows: rows,
         selector_fields: Enum.sort_by(selector_fields, & &1.name),
         text_fields:
           text_fields |> Enum.map(&{&1.name, &1}) |> TextFields.order() |> Enum.map(&elem(&1, 1))
       }}
    end
  end

  defp compile_rows(rows, context) when is_binary(rows),
    do: compile_rows(%{selector: rows}, context)

  defp compile_rows(%{} = rows, context) do
    case fetch(rows, :selector) do
      selector when is_binary(selector) and selector != "" ->
        {:ok,
         %Rows{
           selector: render(selector, context),
           attribute: fetch(rows, :attribute),
           after: non_neg_integer(fetch(rows, :after)),
           count: positive_integer(fetch(rows, :count)),
           andmatch: fetch(rows, :andmatch),
           missing_attribute_equals_no_results:
             fetch(rows, :missing_attribute_equals_no_results) == true,
           multiple: fetch(rows, :multiple) == true,
           filters: compile_filters(fetch(rows, :filters), context)
         }}

      _ ->
        {:error, Error.search_failed("No row selector configured")}
    end
  end

  defp compile_rows(_rows, _context),
    do: {:error, Error.search_failed("No row selector configured")}

  defp compile_fields(fields, context) when is_map(fields) do
    fields
    |> Enum.sort_by(fn {name, _} -> to_string(name) end)
    |> Enum.reduce_while({:ok, []}, fn {name, config}, {:ok, acc} ->
      case compile_field(to_string(name), config, context) do
        {:ok, field} -> {:cont, {:ok, [field | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp compile_fields(_fields, _context),
    do: {:error, Error.search_failed("Invalid fields format")}

  defp compile_field(name, config, context) when is_map(config) do
    {:ok,
     %Field{
       name: name,
       selector: render_optional(fetch(config, :selector), context),
       attribute: fetch(config, :attribute),
       filters: compile_filters(fetch(config, :filters), context),
       remove: compile_remove(fetch(config, :remove), context),
       case: compile_case(fetch(config, :case), context),
       optional: fetch(config, :optional) == true,
       default: fetch(config, :default),
       text: TextFields.text_value(config)
     }}
  end

  defp compile_field(name, _config, _context),
    do: {:error, Error.search_failed("Field #{name} config is not a map")}

  defp compile_remove(nil, _context), do: nil

  defp compile_remove(remove, context),
    do: remove |> List.wrap() |> Enum.map(&render(to_string(&1), context))

  defp compile_case(case_map, context) when is_map(case_map) and map_size(case_map) > 0 do
    case_map
    |> Enum.map(fn {k, v} -> {render(to_string(k), context), to_string(v)} end)
    |> Enum.sort_by(&{elem(&1, 0) == "*", elem(&1, 0)})
  end

  defp compile_case(_case_map, _context), do: nil

  defp compile_filters(filters, context) when is_list(filters),
    do: Enum.map(filters, &compile_filter(&1, context))

  defp compile_filters(_filters, _context), do: []

  # A single string `args` is wrapped in a list, as the filter runner expects.
  defp compile_filter(filter, context) when is_map(filter) do
    key = if Map.has_key?(filter, :args), do: :args, else: "args"

    case fetch(filter, :args) do
      args when is_list(args) -> Map.put(filter, key, Enum.map(args, &render(&1, context)))
      args when is_binary(args) -> Map.put(filter, key, [render(args, context)])
      _ -> filter
    end
  end

  defp compile_filter(filter, _context), do: filter

  defp render_optional(value, context) when is_binary(value), do: render(value, context)
  defp render_optional(value, _context), do: value

  # Templates that read a row's `.Result` can only be rendered per row. A render
  # failure keeps the raw string, as the per-row code did.
  defp render(value, context) when is_binary(value) and map_size(context) > 0 do
    if String.contains?(value, "{{") and not String.contains?(value, ".Result") do
      case CardigannTemplate.render(value, context, url_encode: false) do
        {:ok, rendered} -> rendered
        {:error, _} -> value
      end
    else
      value
    end
  end

  defp render(value, _context), do: value

  # A config key, however the definition spelled it. `false` is a real value.
  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when not is_nil(value) -> value
      _ -> Map.get(map, Atom.to_string(key))
    end
  end

  defp non_neg_integer(n) when is_integer(n) and n > 0, do: n
  defp non_neg_integer(_), do: 0

  defp positive_integer(n) when is_integer(n) and n > 0, do: n
  defp positive_integer(_), do: nil
end
