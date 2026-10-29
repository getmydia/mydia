defmodule Mydia.Indexers.Cardigann.Result.Pipeline do
  @moduledoc false
  # Response body to search results, the same way for HTML, JSON and XML:
  # parse the document, list and slice its rows, extract each row's fields,
  # drop rows `andmatch` rejects, transform and count what happened. Only the
  # format adapter differs per format.

  require Logger

  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.Cardigann.JsonPath
  alias Mydia.Indexers.Cardigann.ParseStats
  alias Mydia.Indexers.Cardigann.Result.{Context, Fields, Plan, Transform}
  alias Mydia.Indexers.Cardigann.Result.Format.{Html, Json, Xml}
  alias Mydia.Indexers.Cardigann.Selector

  @adapters %{html: Html, json: Json, xml: Xml}
  @labels %{html: "HTML", json: "JSON", xml: "XML"}

  @spec run(Plan.t(), binary() | map() | list(), Context.t()) ::
          {:ok, [Mydia.Indexers.SearchResult.t()], ParseStats.t()} | {:error, Error.t()}
  def run(%Plan{format: format} = plan, body, %Context{} = ctx) do
    adapter = Map.fetch!(@adapters, format)

    with {:ok, document} <- adapter.document(body, plan),
         {:ok, rows} <- rows(adapter, document, plan, ctx) do
      Logger.info("[#{ctx.indexer_name}] Extracted #{length(rows)} rows from #{@labels[format]}")
      parse_rows(adapter, document, rows, plan, ctx)
    else
      {:error, reason} -> error(reason, format, ctx.indexer_name)
    end
  rescue
    error -> parse_failure(error, format, ctx.indexer_name)
  end

  @doc false
  # lexbor rejected a selector in the definition: Selector.find/3 names it in
  # the message, and the indexer makes it traceable to a definition. Anything
  # else is the format's generic parse failure, which LiveCheck classifies by
  # its "Failed to parse <FORMAT>" prefix.
  @spec parse_failure(Exception.t() | term(), :html | :json | :xml | nil, String.t()) ::
          {:error, Error.t()}
  def parse_failure(error, format, indexer_name) do
    if Selector.selector_error?(error) do
      message = Exception.message(error)
      Logger.error("Invalid selector in #{indexer_name} definition: #{message}")

      {:error,
       Error.search_failed("Invalid selector in the #{indexer_name} definition: #{message}")}
    else
      label = Map.get(@labels, format, "unknown")
      Logger.error("#{label} parsing error for #{indexer_name}: #{inspect(error)}")

      {:error,
       Error.search_failed(
         "Failed to parse #{label} response from #{indexer_name}: #{inspect(error)}"
       )}
    end
  end

  defp rows(Json, document, plan, ctx) do
    if JsonPath.reports_no_results?(document, ctx.search),
      do: {:ok, []},
      else: slice(Json.rows(document, plan.rows), plan, document, Json, ctx)
  end

  defp rows(adapter, document, plan, ctx),
    do: slice(adapter.rows(document, plan.rows), plan, document, adapter, ctx)

  defp slice({:error, _} = error, _plan, _document, _adapter, _ctx), do: error

  defp slice(found, %Plan{rows: rows}, document, adapter, ctx) do
    if found == [], do: log_empty(adapter, document, rows.selector, ctx.indexer_name)
    after_skip = Enum.drop(found, rows.after)
    {:ok, if(rows.count, do: Enum.take(after_skip, rows.count), else: after_skip)}
  end

  defp log_empty(adapter, document, selector, indexer_name) do
    Logger.debug(fn ->
      details =
        if function_exported?(adapter, :empty_rows_diagnostics, 1),
          do: ": " <> adapter.empty_rows_diagnostics(document),
          else: ""

      "[#{indexer_name}] row selector #{inspect(selector)} matched nothing#{details}"
    end)
  end

  defp parse_rows(adapter, document, rows, plan, ctx) do
    {parsed, drops} =
      rows
      |> Enum.map(&Fields.extract(document, &1, plan, adapter, ctx.template_context))
      |> partition()

    kept = andmatch(parsed, plan, ctx.template_context)

    results = Transform.search_results(kept, ctx)

    Logger.info("[#{ctx.indexer_name}] Transformed #{length(kept)} rows to #{length(results)}")

    stats = %ParseStats{
      matched: length(rows),
      filtered: length(parsed) - length(kept),
      dropped: length(drops) + length(kept) - length(results),
      first_missing: List.first(drops)
    }

    log_dropped(stats, ctx.indexer_name)
    {:ok, results, stats}
  end

  defp partition(extracted) do
    {kept, drops} = Enum.split_with(extracted, &match?({:ok, _}, &1))
    {Enum.map(kept, &elem(&1, 1)), Enum.map(drops, &elem(&1, 1))}
  end

  # `andmatch` drops rows whose title lacks any search keyword. Definitions
  # declare it on `rows.filters`, where Prowlarr reads it, or as a field
  # filter, which the native engine has always honoured too.
  defp andmatch(rows, plan, template_context) do
    words =
      (template_context[:keywords] || "")
      |> String.downcase()
      |> String.split(~r/\s+/, trim: true)

    if words != [] and andmatch?(plan) do
      Enum.filter(rows, fn row ->
        title = row |> Map.get("title", "") |> String.downcase()
        Enum.all?(words, &String.contains?(title, &1))
      end)
    else
      rows
    end
  end

  defp andmatch?(%Plan{rows: rows} = plan) do
    rows.andmatch == true or
      Enum.any?(
        [rows.filters | Enum.map(plan.selector_fields ++ plan.text_fields, & &1.filters)],
        &Enum.any?(&1, fn filter -> filter_name(filter) == "andmatch" end)
      )
  end

  defp filter_name(%{} = filter), do: to_string(filter[:name] || filter["name"])
  defp filter_name(_filter), do: nil

  defp log_dropped(%ParseStats{dropped: 0}, _indexer_name), do: :ok

  defp log_dropped(%ParseStats{} = stats, indexer_name) do
    Logger.warning(
      "[#{indexer_name}] #{stats.matched} rows matched, #{stats.dropped} dropped (first missing: #{stats.first_missing || "unknown"})"
    )
  end

  defp error(%Error{} = error, _format, _indexer_name), do: {:error, error}

  defp error(%Jason.DecodeError{} = error, _format, _indexer_name),
    do: {:error, Error.search_failed("Invalid JSON: #{inspect(error)}")}

  defp error(message, _format, _indexer_name) when is_binary(message),
    do: {:error, Error.search_failed(message)}

  defp error(reason, format, indexer_name), do: parse_failure(reason, format, indexer_name)
end
