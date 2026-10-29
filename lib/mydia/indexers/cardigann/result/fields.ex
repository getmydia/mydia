defmodule Mydia.Indexers.Cardigann.Result.Fields do
  @moduledoc false
  # The one field extractor for every response format. Prowlarr walks a row's
  # fields in definition order and exposes each value as `.Result.<name>` to
  # the fields after it. The parsed definition has lost that order, so this
  # runs two passes: selector fields in dependency order (the plan's order),
  # each seeing the values extracted before it, then text fields in dependency
  # order, each seeing everything so far. Filters run after `case`, with the
  # same `.Result` the field's selector saw.

  require Logger

  alias Mydia.Indexers.Cardigann.Result.Plan
  alias Mydia.Indexers.Cardigann.Result.Plan.{Field, RowTemplate}
  alias Mydia.Indexers.Cardigann.Result.Format.Template
  alias Mydia.Indexers.CardigannFilters
  alias Mydia.Indexers.CardigannTemplate

  @spec extract(term(), term(), Plan.t(), module(), map()) ::
          {:ok, %{String.t() => String.t()}} | {:drop, String.t()}
  def extract(document, row, %Plan{} = plan, format, template_context) do
    template_context = template_context || %{}

    plan.selector_fields
    |> Enum.reduce(%{}, &put_selector_field(&1, &2, document, row, {format, template_context}))
    |> then(
      &Enum.reduce(plan.text_fields, &1, fn f, acc -> put_text_field(f, acc, template_context) end)
    )
    |> combine_compound_fields()
    |> require_title_and_download()
  end

  defp put_selector_field(%Field{} = field, values, document, row, {format, template_context}) do
    context = Map.put(template_context, :result, values)

    case selector_value(field, document, row, format, context) do
      {:ok, value} -> Map.put(values, field.name, value)
      :not_found -> values
    end
  end

  defp selector_value(field, document, row, format, context) do
    case lookup(field, document, row, format, context) do
      {:ok, raw} -> filter(raw, field, context)
      :not_found -> default(field, context)
    end
  end

  defp lookup(%Field{case: nil} = field, document, row, format, context),
    do: format.raw(document, row, field, context: context)

  defp lookup(%Field{} = field, document, row, format, context),
    do: format.case_value(document, row, field, context: context)

  # The v11 schema declares `default` dependentRequired on `optional`, so a
  # default on a required field is a malformed definition, not a licence to
  # invent a value.
  defp default(%Field{optional: true, default: default} = field, context)
       when not is_nil(default),
       do: filter(to_string(default), field, context)

  defp default(_field, _context), do: :not_found

  defp put_text_field(%Field{} = field, values, template_context) do
    context = Map.put(template_context, :result, values)

    case render_text(field.text, context) do
      {:ok, rendered} ->
        {:ok, value} = filter(String.trim(rendered), field, context)
        Map.put(values, field.name, value)

      :error ->
        values
    end
  end

  defp render_text(text, context) do
    case CardigannTemplate.render(text, context, url_encode: false) do
      {:ok, rendered} ->
        {:ok, rendered}

      {:error, reason} ->
        Logger.debug("Text field template render failed: #{inspect(reason)}")
        :error
    end
  rescue
    e ->
      Logger.warning("Template render exception: #{inspect(e)}, template: #{inspect(text)}")
      :error
  end

  # The plan rendered every filter argument that does not read `.Result`, so
  # only those that do are rendered here, once, against this row.
  defp filter(value, %Field{filters: filters}, context) do
    {:ok,
     Enum.reduce(filters, value, fn filter, acc ->
       {:ok, filtered} = CardigannFilters.apply(render_args(filter, context), acc)
       filtered
     end)}
  end

  defp render_args(%{} = filter, context) do
    key = if Map.has_key?(filter, :args), do: :args, else: "args"

    case Map.get(filter, key) do
      args when is_list(args) ->
        Map.put(filter, key, Enum.map(args, &render_arg(&1, context)))

      _ ->
        filter
    end
  end

  defp render_args(filter, _context), do: filter

  # Only an argument the plan marked is a template; anything else is final text,
  # even when a keyword it carries spells out `{{ .Result... }}`.
  defp render_arg(%RowTemplate{template: template}, context),
    do: Template.render(template, context: context)

  defp render_arg(arg, _context), do: arg

  # Definitions that predate `text:` spell a fallback title as title_default
  # plus title_optional, and a download as download2 or magnet. Fold them into
  # the names the transform reads.
  defp combine_compound_fields(values) do
    values
    |> combine_title_fields()
    |> combine_download_fields()
  end

  defp combine_title_fields(values) do
    if present(values, "title") do
      values
    else
      case pick_title(present(values, "title_default"), present(values, "title_optional")) do
        nil ->
          values

        title ->
          values |> Map.put("title", title) |> Map.drop(["title_default", "title_optional"])
      end
    end
  end

  # A default ending in "..." was truncated by the site; the optional one is whole.
  defp pick_title(default, optional) when is_binary(default) and is_binary(optional),
    do: if(String.contains?(default, "..."), do: optional, else: default)

  defp pick_title(default, optional), do: default || optional

  # download wins; otherwise download2, then `magnet`. Definitions such as
  # nekobt name the link `magnet` (it holds a magnet or a torrent URL) and have
  # no `download` field.
  defp combine_download_fields(values) do
    cond do
      present(values, "download") -> values
      value = present(values, "download2") -> promote_download(values, "download2", value)
      value = present(values, "magnet") -> promote_download(values, "magnet", value)
      true -> values
    end
  end

  defp promote_download(values, from, value),
    do: values |> Map.put("download", value) |> Map.delete(from)

  defp present(values, key) do
    case Map.get(values, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  # A row is kept only when it has a title and a download or infohash.
  # Otherwise it is reported as dropped with the missing field's name (title
  # wins when both are missing).
  defp require_title_and_download(values) do
    cond do
      not Map.has_key?(values, "title") -> {:drop, "title"}
      not Enum.any?(["download", "infohash"], &Map.has_key?(values, &1)) -> {:drop, "download"}
      true -> {:ok, values}
    end
  end
end
