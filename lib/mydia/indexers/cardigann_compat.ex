defmodule Mydia.Indexers.CardigannCompat do
  @moduledoc """
  Analyzes Cardigann indexer definitions for compatibility with our native engine.

  Downloads all v11 definitions from the Prowlarr/Indexers GitHub repository,
  scores each one against the declared feature registry, and produces a
  compatibility report ranked by which unsupported features block the most
  definitions.
  """

  require Logger

  alias Mydia.Indexers.Cardigann.Features
  alias Mydia.Indexers.CardigannParser
  alias Mydia.Indexers.DefinitionSync

  @supported MapSet.new(Features.supported())

  @doc """
  Runs a full compatibility analysis against all upstream definitions.

  ## Options

  - `:limit` - Maximum number of definitions to analyze (default: all)
  - `:cache_dir` - Directory to cache downloaded definitions (default: nil, no caching)
  - `:type` - Filter definitions by privacy type (`"public"`, `"private"`,
    `"semi-private"`, or `"all"`)

  ## Returns

  `{:ok, report}` where report is a map with:
  - `:total` - Total definitions analyzed
  - `:parsed` - Successfully analyzed count
  - `:parse_failed` - Failed to analyze count
  - `:fully_supported` - All required features are implemented
  - `:partially_supported` - Uses at least one unsupported feature
  - `:by_feature` - Feature atom to count of definitions that feature blocks
  - `:definitions` - List of per-definition analysis results
  - `:parse_failures` - List of `{filename, reason}` tuples
  """
  def analyze(opts \\ []) do
    limit = Keyword.get(opts, :limit)
    cache_dir = Keyword.get(opts, :cache_dir)
    type_filter = Keyword.get(opts, :type)

    with {:ok, files} <- list_definitions(),
         files <- maybe_limit(files, limit),
         {:ok, yamls} <- fetch_all_definitions(files, cache_dir) do
      results =
        yamls
        |> analyze_definitions()
        |> maybe_filter_by_type(type_filter)

      {:ok, build_report(results)}
    end
  end

  @doc """
  Analyzes a single YAML definition string and returns its compatibility status.

  ## Returns

  A map with:
  - `:name` - Definition name or filename
  - `:id` - Definition id when present
  - `:type` - Privacy type when present
  - `:status` - `:fully_supported`, `:partially_supported`, or `:parse_failed`
  - `:required_features` - List of feature atoms the definition needs
  - `:missing_features` - Required features not in the supported registry
  - `:error` - Error reason if analysis failed
  """
  def analyze_definition(yaml_content, filename \\ "unknown") do
    case YamlElixir.read_from_string(yaml_content) do
      {:ok, yaml_data} ->
        if definition_analyzable?(yaml_data) do
          analyze_yaml(yaml_data, yaml_content, filename)
        else
          parse_failed_result(
            filename,
            {:missing_required_fields, missing_analysis_fields(yaml_data)}
          )
        end

      {:error, reason} ->
        parse_failed_result(filename, {:yaml_parse_error, reason})
    end
  end

  @doc """
  Builds an aggregate compatibility report from per-definition analysis results.
  """
  def build_report(results) do
    total = length(results)
    parsed = Enum.count(results, &(&1.status != :parse_failed))
    parse_failed = total - parsed
    fully_supported = Enum.count(results, &(&1.status == :fully_supported))
    partially_supported = Enum.count(results, &(&1.status == :partially_supported))

    by_feature =
      results
      |> Enum.filter(&(&1.status == :partially_supported))
      |> Enum.flat_map(& &1.missing_features)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_feature, count} -> -count end)

    parse_failures =
      results
      |> Enum.filter(&(&1.status == :parse_failed))
      |> Enum.map(&{&1.name, &1.error})

    %{
      total: total,
      parsed: parsed,
      parse_failed: parse_failed,
      fully_supported: fully_supported,
      partially_supported: partially_supported,
      by_feature: by_feature,
      definitions: results,
      parse_failures: parse_failures
    }
  end

  @doc """
  Extracts all filter names from raw YAML data (before full parsing).

  This is a fallback for definitions that fail to parse - we can still
  scan the raw YAML map for filter references.
  """
  def extract_filters_from_yaml(yaml_string) when is_binary(yaml_string) do
    case YamlElixir.read_from_string(yaml_string) do
      {:ok, data} -> extract_filters_from_yaml_data(data)
      {:error, _} -> []
    end
  end

  defp analyze_yaml(yaml_data, yaml_content, filename) do
    required = Features.required(yaml_data)
    missing = MapSet.difference(required, @supported) |> MapSet.to_list()

    status =
      if missing == [] do
        :fully_supported
      else
        :partially_supported
      end

    metadata = definition_metadata(yaml_data, yaml_content, filename)

    Map.merge(metadata, %{
      status: status,
      required_features: MapSet.to_list(required),
      missing_features: missing,
      error: nil
    })
  end

  defp definition_metadata(yaml_data, yaml_content, filename) do
    case CardigannParser.parse_definition(yaml_content) do
      {:ok, parsed} ->
        %{name: parsed.name, id: parsed.id, type: parsed.type}

      {:error, _} ->
        %{
          name: Map.get(yaml_data, "name", filename),
          id: Map.get(yaml_data, "id"),
          type: Map.get(yaml_data, "type")
        }
    end
  end

  defp definition_analyzable?(yaml_data) do
    missing_analysis_fields(yaml_data) == []
  end

  defp missing_analysis_fields(yaml_data) do
    []
    |> maybe_missing_field(yaml_data, "id")
    |> maybe_missing_field(yaml_data, "name")
    |> maybe_missing_search(yaml_data)
  end

  defp maybe_missing_field(missing, yaml_data, key) do
    if present?(Map.get(yaml_data, key)), do: missing, else: [key | missing]
  end

  defp maybe_missing_search(missing, yaml_data) do
    case Map.get(yaml_data, "search") do
      search when is_map(search) -> missing
      _ -> ["search" | missing]
    end
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true

  defp parse_failed_result(filename, reason) do
    %{
      name: filename,
      id: nil,
      type: nil,
      status: :parse_failed,
      required_features: [],
      missing_features: [],
      error: reason
    }
  end

  defp list_definitions do
    DefinitionSync.list_definition_files()
  end

  defp maybe_limit(files, nil), do: files
  defp maybe_limit(files, limit), do: Enum.take(files, limit)

  defp maybe_filter_by_type(results, nil), do: results
  defp maybe_filter_by_type(results, "all"), do: results

  defp maybe_filter_by_type(results, type) when is_binary(type),
    do: Enum.filter(results, &(&1.type == type))

  defp maybe_filter_by_type(results, _), do: results

  defp fetch_all_definitions(files, cache_dir) do
    if cache_dir do
      File.mkdir_p!(cache_dir)
    end

    results =
      Task.async_stream(
        files,
        fn file -> fetch_single_definition(file, cache_dir) end,
        max_concurrency: 5,
        timeout: 60_000,
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    yamls =
      Enum.flat_map(results, fn
        {:ok, {:ok, yaml}} ->
          [yaml]

        {:ok, {:error, reason}} ->
          Logger.warning("[CardigannCompat] Failed to fetch: #{inspect(reason)}")
          []

        {:exit, reason} ->
          Logger.warning("[CardigannCompat] Task failed: #{inspect(reason)}")
          []
      end)

    {:ok, yamls}
  end

  defp fetch_single_definition(file, cache_dir) do
    filename = Map.get(file, "name")
    download_url = Map.get(file, "download_url")

    cached = if cache_dir, do: read_cache(cache_dir, filename), else: nil

    case cached do
      {:ok, content} ->
        {:ok, {filename, content}}

      _ ->
        case DefinitionSync.fetch_definition_file(download_url) do
          {:ok, content} ->
            if cache_dir, do: write_cache(cache_dir, filename, content)
            {:ok, {filename, content}}

          error ->
            error
        end
    end
  end

  defp read_cache(cache_dir, filename) do
    path = Path.join(cache_dir, filename)

    if File.exists?(path) do
      case File.stat(path) do
        {:ok, %{mtime: mtime}} ->
          cache_age_seconds =
            :calendar.datetime_to_gregorian_seconds(:calendar.local_time()) -
              :calendar.datetime_to_gregorian_seconds(mtime)

          if cache_age_seconds < 86_400 do
            File.read(path)
          else
            nil
          end

        _ ->
          nil
      end
    else
      nil
    end
  end

  defp write_cache(cache_dir, filename, content) do
    path = Path.join(cache_dir, filename)
    File.write(path, content)
  end

  defp analyze_definitions(yamls) do
    Enum.map(yamls, fn {filename, yaml_content} ->
      analyze_definition(yaml_content, filename)
    end)
  end

  defp extract_filters_from_yaml_data(data) when is_map(data) do
    search = Map.get(data, "search", %{})
    fields = Map.get(search, "fields", %{})

    Enum.flat_map(fields, fn
      {_field_name, %{"filters" => filters}} when is_list(filters) ->
        Enum.map(filters, fn
          %{"name" => name} -> name
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  defp extract_filters_from_yaml_data(_), do: []
end
