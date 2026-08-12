defmodule Mix.Tasks.Mydia.CardigannCompat do
  @moduledoc """
  Analyzes Cardigann indexer compatibility with our native engine.

  Downloads all v11 definitions from Prowlarr/Indexers GitHub repository,
  scores each one against the feature registry, and generates a report showing
  which unsupported features block the most definitions.

  ## Usage

      mix mydia.cardigann_compat [options]

  ## Options

      --limit N       Analyze only the first N definitions (useful for testing)
      --type TYPE     Filter by privacy type: public, private, semi-private, or all
      --cache         Cache downloaded definitions to speed up repeated runs
      --verbose       Show per-definition details
      --json          Output report as JSON

  ## Examples

      mix mydia.cardigann_compat
      mix mydia.cardigann_compat --type public
      mix mydia.cardigann_compat --limit 50
      mix mydia.cardigann_compat --cache --verbose
  """

  use Mix.Task

  @shortdoc "Analyzes Cardigann indexer definition compatibility"

  @impl Mix.Task
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args,
        strict: [
          limit: :integer,
          type: :string,
          cache: :boolean,
          verbose: :boolean,
          json: :boolean
        ]
      )

    Mix.Task.run("app.start")

    limit = opts[:limit]
    type = opts[:type]
    verbose = opts[:verbose] || false
    json = opts[:json] || false

    cache_dir =
      if opts[:cache] do
        Path.join([Mix.Project.build_path(), "cardigann_compat_cache"])
      else
        nil
      end

    analyze_opts =
      [limit: limit, type: type, cache_dir: cache_dir]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    Mix.shell().info("Analyzing Cardigann definitions...")

    case Mydia.Indexers.CardigannCompat.analyze(analyze_opts) do
      {:ok, report} ->
        if json do
          print_json_report(report)
        else
          print_report(report, verbose)
        end

      {:error, reason} ->
        Mix.shell().error("Analysis failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp print_report(report, verbose) do
    Mix.shell().info("")
    Mix.shell().info("=== Cardigann Compatibility Report ===")
    Mix.shell().info("")

    Mix.shell().info("Summary:")
    Mix.shell().info("  Total definitions:      #{report.total}")
    Mix.shell().info("  Successfully analyzed:  #{report.parsed}")
    Mix.shell().info("  Analysis failures:      #{report.parse_failed}")
    Mix.shell().info("  Fully supported:        #{report.fully_supported}")
    Mix.shell().info("  Partially supported:    #{report.partially_supported}")
    Mix.shell().info("")

    parse_rate =
      if report.total > 0,
        do: Float.round(report.parsed / report.total * 100, 1),
        else: 0.0

    support_rate =
      if report.parsed > 0,
        do: Float.round(report.fully_supported / report.parsed * 100, 1),
        else: 0.0

    Mix.shell().info("  Analysis success rate:  #{parse_rate}%")
    Mix.shell().info("  Full support rate:      #{support_rate}% (of analyzed)")
    Mix.shell().info("")

    if report.by_feature != [] do
      Mix.shell().info("Unsupported Features (definitions blocked):")
      Mix.shell().info(String.duplicate("-", 50))

      supported = MapSet.new(Mydia.Indexers.Cardigann.Features.supported())

      Enum.each(report.by_feature, fn {feature, count} ->
        status = if feature in supported, do: "[OK]", else: "[MISSING]"

        Mix.shell().info(
          "  #{String.pad_trailing(to_string(feature), 35)} #{String.pad_leading(to_string(count), 5)}  #{status}"
        )
      end)

      Mix.shell().info("")
    end

    if report.parse_failures != [] do
      failures_to_show =
        if verbose, do: report.parse_failures, else: Enum.take(report.parse_failures, 10)

      Mix.shell().info("Analysis Failures#{unless verbose, do: " (top 10)"}:")
      Mix.shell().info(String.duplicate("-", 50))

      Enum.each(failures_to_show, fn {name, reason} ->
        Mix.shell().info("  #{name}: #{format_error(reason)}")
      end)

      if not verbose and length(report.parse_failures) > 10 do
        Mix.shell().info(
          "  ... and #{length(report.parse_failures) - 10} more (use --verbose to see all)"
        )
      end

      Mix.shell().info("")
    end

    if verbose do
      Mix.shell().info("Per-Definition Details:")
      Mix.shell().info(String.duplicate("-", 80))

      report.definitions
      |> Enum.sort_by(& &1.name)
      |> Enum.each(fn defn ->
        status_str =
          case defn.status do
            :fully_supported -> "OK"
            :partially_supported -> "PARTIAL"
            :parse_failed -> "FAILED"
          end

        missing_str =
          if defn.missing_features != [] do
            " missing: #{Enum.map_join(defn.missing_features, ", ", &to_string/1)}"
          else
            ""
          end

        Mix.shell().info("  [#{status_str}] #{defn.name}#{missing_str}")
      end)

      Mix.shell().info("")
    end
  end

  defp print_json_report(report) do
    json_data = %{
      summary: %{
        total: report.total,
        parsed: report.parsed,
        parse_failed: report.parse_failed,
        fully_supported: report.fully_supported,
        partially_supported: report.partially_supported
      },
      by_feature: Map.new(report.by_feature),
      definitions:
        Enum.map(report.definitions, fn defn ->
          %{
            name: defn.name,
            id: defn.id,
            type: defn.type,
            status: defn.status,
            required_features: defn.required_features,
            missing_features: defn.missing_features,
            error: if(defn.error, do: format_error(defn.error))
          }
        end)
    }

    Mix.shell().info(Jason.encode!(json_data, pretty: true))
  end

  defp format_error({:missing_required_field, field}), do: "missing required field: #{field}"
  defp format_error({:missing_required_fields, fields}), do: "missing fields: #{inspect(fields)}"
  defp format_error({:parse_error, msg}), do: "parse error: #{msg}"
  defp format_error({:yaml_parse_error, _} = err), do: "YAML error: #{inspect(err)}"
  defp format_error(:missing_search_path), do: "missing search path"
  defp format_error(:missing_rows_selector), do: "missing rows selector"
  defp format_error(:missing_fields), do: "missing search fields"
  defp format_error(:missing_capabilities), do: "missing capabilities"
  defp format_error(other), do: inspect(other)
end
