defmodule Mydia.Indexers.DefinitionSync do
  @moduledoc """
  Synchronizes Cardigann indexer definitions from the Prowlarr/Indexers GitHub repository.

  Fetches YAML definitions from GitHub and stores them in the database for native indexer support.
  """

  require Logger
  alias Mydia.Repo
  alias Mydia.Indexers.CardigannDefinition

  @github_api_base "https://api.github.com"
  @github_repo "Prowlarr/Indexers"
  @definitions_path "definitions/v11"
  @user_agent "Mydia/1.0"

  @doc """
  Synchronizes all indexer definitions from GitHub.

  Returns `{:ok, stats}` with sync statistics or `{:error, reason}` if the sync fails.

  ## Examples

      iex> Mydia.Indexers.DefinitionSync.sync_from_github()
      {:ok, %{fetched: 150, created: 50, updated: 100, failed: 0}}
  """
  def sync_from_github(opts \\ []) do
    Logger.info("[DefinitionSync] Starting sync from GitHub repository #{@github_repo}")
    start_time = System.monotonic_time(:millisecond)

    stats = %{fetched: 0, created: 0, updated: 0, failed: 0, skipped: 0}

    with {:ok, files} <- list_definition_files(),
         {:ok, stats} <- process_files(files, stats, opts) do
      duration = System.monotonic_time(:millisecond) - start_time

      Logger.info(
        "[DefinitionSync] Sync completed in #{duration}ms: " <>
          "#{stats.fetched} fetched, #{stats.created} created, " <>
          "#{stats.updated} updated, #{stats.skipped} skipped, #{stats.failed} failed"
      )

      {:ok, stats}
    else
      {:error, reason} = error ->
        Logger.error("[DefinitionSync] Sync failed: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Lists all YAML definition files in the v11 directory on GitHub.
  """
  def list_definition_files do
    url = "#{@github_api_base}/repos/#{@github_repo}/contents/#{@definitions_path}"

    headers = [
      {"accept", "application/vnd.github.v3+json"},
      {"user-agent", @user_agent}
    ]

    Logger.debug("[DefinitionSync] Fetching file list from #{url}")

    case Req.get(url, headers: headers, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: files}} when is_list(files) ->
        yaml_files =
          files
          |> Enum.filter(fn file ->
            Map.get(file, "type") == "file" and String.ends_with?(Map.get(file, "name"), ".yml")
          end)

        Logger.info("[DefinitionSync] Found #{length(yaml_files)} YAML definition files")
        {:ok, yaml_files}

      {:ok, %{status: 403}} ->
        Logger.error("[DefinitionSync] GitHub API rate limit exceeded")
        {:error, :rate_limit_exceeded}

      {:ok, %{status: 404}} ->
        Logger.error("[DefinitionSync] Repository or path not found")
        {:error, :not_found}

      {:ok, %{status: status}} ->
        Logger.error("[DefinitionSync] Unexpected status code: #{status}")
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        Logger.error("[DefinitionSync] Failed to fetch file list: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Fetches a single YAML definition file from GitHub.
  """
  def fetch_definition_file(download_url) do
    headers = [
      {"user-agent", @user_agent}
    ]

    case Req.get(download_url, headers: headers, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: content}} when is_binary(content) ->
        {:ok, content}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Parses YAML definition and extracts metadata.
  """
  def parse_definition(yaml_content, filename) do
    case YamlElixir.read_from_string(yaml_content) do
      {:ok, data} when is_map(data) ->
        indexer_id = extract_indexer_id(data, filename)

        definition_attrs = %{
          indexer_id: indexer_id,
          name: Map.get(data, "name") || indexer_id,
          description: Map.get(data, "description"),
          language: Map.get(data, "language"),
          type: Map.get(data, "type") || "public",
          encoding: Map.get(data, "encoding"),
          links: normalize_links(Map.get(data, "links", [])),
          capabilities: Map.get(data, "caps") || %{},
          definition: yaml_content,
          schema_version: "v11",
          last_synced_at: DateTime.utc_now()
        }

        {:ok, definition_attrs}

      {:ok, _} ->
        {:error, :invalid_format}

      {:error, reason} ->
        Logger.error("[DefinitionSync] Failed to parse YAML: #{inspect(reason)}")
        {:error, {:yaml_parse_error, reason}}
    end
  end

  @doc """
  Upserts a definition into the database.
  """
  def upsert_definition(attrs) do
    indexer_id = Map.get(attrs, :indexer_id)

    case Repo.get_by(CardigannDefinition, indexer_id: indexer_id) do
      nil ->
        # Create new definition
        %CardigannDefinition{}
        |> CardigannDefinition.changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, definition} ->
            Logger.debug("[DefinitionSync] Created definition for #{indexer_id}")
            {:ok, :created, definition}

          {:error, changeset} ->
            Logger.error(
              "[DefinitionSync] Failed to create #{indexer_id}: #{inspect(changeset.errors)}"
            )

            {:error, changeset}
        end

      existing ->
        # Update existing definition (preserve user's enabled/config settings)
        existing
        |> CardigannDefinition.changeset(Map.drop(attrs, [:enabled, :in_library, :config]))
        |> Repo.update()
        |> case do
          {:ok, definition} ->
            Logger.debug("[DefinitionSync] Updated definition for #{indexer_id}")
            {:ok, :updated, definition}

          {:error, changeset} ->
            Logger.error(
              "[DefinitionSync] Failed to update #{indexer_id}: #{inspect(changeset.errors)}"
            )

            {:error, changeset}
        end
    end
  end

  # Private functions

  defp process_files(files, stats, opts) do
    max_files = Keyword.get(opts, :limit)

    files_to_process =
      if max_files do
        Enum.take(files, max_files)
      else
        files
      end

    results =
      Task.async_stream(
        files_to_process,
        fn file -> process_single_file(file) end,
        max_concurrency: 5,
        timeout: 60_000,
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    # Aggregate results
    final_stats =
      Enum.reduce(results, stats, fn result, acc ->
        case result do
          {:ok, {:ok, :created}} ->
            %{acc | fetched: acc.fetched + 1, created: acc.created + 1}

          {:ok, {:ok, :updated}} ->
            %{acc | fetched: acc.fetched + 1, updated: acc.updated + 1}

          {:ok, {:error, _reason}} ->
            %{acc | failed: acc.failed + 1}

          {:exit, _reason} ->
            %{acc | failed: acc.failed + 1}
        end
      end)

    {:ok, final_stats}
  end

  defp process_single_file(file) do
    filename = Map.get(file, "name")
    download_url = Map.get(file, "download_url")

    Logger.debug("[DefinitionSync] Processing #{filename}")

    with {:ok, content} <- fetch_definition_file(download_url),
         {:ok, attrs} <- parse_definition(content, filename),
         {:ok, action, _definition} <- upsert_definition(attrs) do
      {:ok, action}
    else
      {:error, reason} ->
        Logger.error("[DefinitionSync] Failed to process #{filename}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp extract_indexer_id(data, filename) do
    # Try to get ID from YAML, otherwise use filename without extension
    Map.get(data, "id") || Path.rootname(filename)
  end

  defp normalize_links(links) when is_list(links) do
    Enum.into(links, %{}, fn link ->
      case link do
        url when is_binary(url) -> {"default", url}
        _ -> link
      end
    end)
  end

  defp normalize_links(links) when is_map(links), do: links
  defp normalize_links(_), do: %{}
end
