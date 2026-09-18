defmodule Mix.Tasks.Mydia.CardigannHealth do
  @moduledoc """
  Tests the health of enabled Cardigann indexers.

  Performs a test search against each enabled Cardigann indexer definition
  and reports success/failure/error status.

  ## Usage

      mix mydia.cardigann_health [options]

  ## Options

      --indexer ID    Test only the specified indexer (by indexer_id)
      --query TEXT    Custom search query (default: "test")
      --json          Output results as JSON
      --timeout MS    Timeout per indexer in milliseconds (default: 15000)

  ## Examples

      mix mydia.cardigann_health
      mix mydia.cardigann_health --indexer 1337x
      mix mydia.cardigann_health --json
  """

  use Mix.Task

  @shortdoc "Tests health of enabled Cardigann indexers"

  alias Mydia.Indexers.CardigannDefinition
  alias Mydia.Indexers.CardigannParser
  alias Mydia.Indexers.CardigannSearchEngine
  alias Mydia.Indexers.CardigannResultParser
  alias Mydia.Repo

  import Ecto.Query

  @impl Mix.Task
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args,
        strict: [indexer: :string, query: :string, json: :boolean, timeout: :integer]
      )

    Mix.Task.run("app.start")

    query = opts[:query] || "test"
    json = opts[:json] || false
    timeout = opts[:timeout] || 15_000

    definitions = fetch_definitions(opts[:indexer])

    if definitions == [] do
      Mix.shell().info("No Cardigann indexer definitions found.")
      exit({:shutdown, 0})
    end

    Mix.shell().info("Testing #{length(definitions)} Cardigann indexer(s)...\n")

    results =
      Enum.map(definitions, fn definition ->
        test_indexer(definition, query, timeout)
      end)

    if json do
      print_json_results(results)
    else
      print_results(results)
    end
  end

  defp fetch_definitions(nil) do
    CardigannDefinition
    |> where([d], d.enabled == true)
    |> Repo.all()
  end

  defp fetch_definitions(indexer_id) do
    CardigannDefinition
    |> where([d], d.indexer_id == ^indexer_id)
    |> Repo.all()
  end

  defp test_indexer(definition, query, timeout) do
    start_time = System.monotonic_time(:millisecond)
    task = Task.async(fn -> do_test_indexer(definition, query) end)

    result =
      try do
        Task.await(task, timeout)
      rescue
        e ->
          %{status: :error, result_count: 0, error: Exception.message(e)}
      catch
        :exit, {:timeout, _} ->
          Task.shutdown(task, :brutal_kill)
          %{status: :timeout, result_count: 0, error: "Timed out after #{timeout}ms"}
      end

    duration = System.monotonic_time(:millisecond) - start_time

    Map.merge(result, %{
      indexer_id: definition.indexer_id,
      name: definition.name,
      duration_ms: duration
    })
  end

  defp do_test_indexer(definition, query) do
    with {:ok, parsed} <- CardigannParser.parse_definition(definition.definition),
         base_url <- List.first(parsed.links) || "",
         search_opts <- [
           query: query,
           categories: [],
           search_path: List.first(parsed.search.paths)
         ],
         {:ok, response} <- CardigannSearchEngine.execute_search(parsed, search_opts, %{}),
         {:ok, results} <-
           CardigannResultParser.parse_results(parsed, response, definition.name,
             base_url: base_url
           ) do
      %{
        status: :ok,
        result_count: length(results),
        error: nil
      }
    else
      {:error, reason} ->
        %{
          status: :error,
          result_count: 0,
          error: format_error(reason)
        }
    end
  end

  defp print_results(results) do
    successes = Enum.count(results, &(&1.status == :ok))
    failures = Enum.count(results, &(&1.status != :ok))

    results
    |> Enum.sort_by(& &1.name)
    |> Enum.each(fn result ->
      status_icon =
        case result.status do
          :ok -> "OK"
          :timeout -> "TIMEOUT"
          :error -> "FAIL"
        end

      line =
        "  [#{status_icon}] #{String.pad_trailing(result.name, 30)} " <>
          "#{String.pad_leading(to_string(result.result_count), 4)} results  " <>
          "#{result.duration_ms}ms"

      error_line = if result.error, do: "         #{result.error}", else: nil

      Mix.shell().info(line)
      if error_line, do: Mix.shell().info(error_line)
    end)

    Mix.shell().info("")
    Mix.shell().info(String.duplicate("-", 60))
    Mix.shell().info("  Total: #{length(results)}  OK: #{successes}  Failed: #{failures}")
    Mix.shell().info("")
  end

  defp print_json_results(results) do
    json_data = %{
      total: length(results),
      ok: Enum.count(results, &(&1.status == :ok)),
      failed: Enum.count(results, &(&1.status != :ok)),
      results:
        Enum.map(results, fn r ->
          %{
            indexer_id: r.indexer_id,
            name: r.name,
            status: r.status,
            result_count: r.result_count,
            duration_ms: r.duration_ms,
            error: r.error
          }
        end)
    }

    Mix.shell().info(Jason.encode!(json_data, pretty: true))
  end

  defp format_error(%{message: msg}), do: msg
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
