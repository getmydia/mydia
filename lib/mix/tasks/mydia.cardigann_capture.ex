defmodule Mix.Tasks.Mydia.CardigannCapture do
  @moduledoc """
  Captures live HTML/JSON responses from indexers as test fixtures.

  Downloads the YAML definition from Prowlarr/Indexers and captures a live
  search response, saving both to `test/fixtures/cardigann/<indexer_id>/`.

  ## Usage

      mix mydia.cardigann_capture <indexer_id> [search_query]

  ## Examples

      mix mydia.cardigann_capture 1337x "ubuntu"
      mix mydia.cardigann_capture eztv "the office"
      mix mydia.cardigann_capture yts

  ## Output

  Creates a fixture directory with:
  - `definition.yml` - The YAML indexer definition
  - `response.html` or `response.json` - The captured search response
  - `download_response.html` - The captured details/download page (when the definition has a download block)
  - `metadata.json` - Query metadata (query, timestamp, result info, download_source_url)
  """

  use Mix.Task

  require Logger

  @shortdoc "Captures live indexer responses as test fixtures"

  @github_raw_base "https://raw.githubusercontent.com/Prowlarr/Indexers/master/definitions/v11"
  @fixtures_base "test/fixtures/cardigann"
  @user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

  @impl Mix.Task
  def run(args) do
    case args do
      [] ->
        Mix.shell().error("Usage: mix mydia.cardigann_capture <indexer_id> [search_query]")
        System.halt(1)

      [indexer_id | rest] ->
        query = Enum.join(rest, " ")
        query = if query == "", do: "test", else: query

        Mix.Task.run("app.start")
        capture_fixture(indexer_id, query)
    end
  end

  defp capture_fixture(indexer_id, query) do
    Mix.shell().info("Capturing fixture for #{indexer_id} with query: #{inspect(query)}")

    # Step 1: Download the YAML definition
    Mix.shell().info("  Downloading definition...")

    case download_definition(indexer_id) do
      {:ok, yaml_content} ->
        # Step 2: Parse the definition to get search URL
        case Mydia.Indexers.CardigannParser.parse_definition(yaml_content) do
          {:ok, definition} ->
            # Step 3: Build search URL and capture response
            Mix.shell().info("  Capturing search response...")

            case capture_search_response(definition, query) do
              {:ok, response_body, search_url} ->
                download_capture =
                  capture_download_response(definition, response_body, query, search_url)

                save_fixture(
                  indexer_id,
                  yaml_content,
                  response_body,
                  query,
                  search_url,
                  download_capture
                )

              {:error, reason} ->
                Mix.shell().error("  Failed to capture response: #{inspect(reason)}")
                # Still save the definition even without a response
                save_definition_only(indexer_id, yaml_content, query)
            end

          {:error, reason} ->
            Mix.shell().error("  Failed to parse definition: #{inspect(reason)}")
        end

      {:error, reason} ->
        Mix.shell().error("  Failed to download definition: #{inspect(reason)}")
    end
  end

  defp download_definition(indexer_id) do
    url = "#{@github_raw_base}/#{indexer_id}.yml"

    case Req.get(url, headers: [{"user-agent", @user_agent}], receive_timeout: 30_000) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp capture_search_response(definition, query) do
    base_url =
      case definition.links do
        [url | _] when is_binary(url) -> url
        _ -> nil
      end

    if is_nil(base_url) do
      {:error, :no_base_url}
    else
      # Build search URL from definition paths
      search_path = build_search_path(definition, query)

      search_url =
        "#{String.trim_trailing(base_url, "/")}/#{String.trim_leading(search_path, "/")}"

      Mix.shell().info("  Fetching: #{search_url}")

      case Req.get(search_url,
             headers: [{"user-agent", @user_agent}],
             receive_timeout: 30_000,
             redirect: true,
             max_redirects: 5,
             decode_body: false
           ) do
        {:ok, %{status: 200, body: body}} when is_binary(body) ->
          {:ok, body, search_url}

        {:ok, %{status: status}} ->
          {:error, {:http_status, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_search_path(definition, query) do
    paths = definition.search[:paths] || []
    inputs = definition.search[:inputs] || %{}

    # Use the first search path
    path_template =
      case paths do
        [%{path: path} | _] -> path
        _ -> "/search/{keywords}/"
      end

    # Match runtime, which filters the query through search.keywordsfilters
    # before substituting {{ .Keywords }}. Capturing with the raw query would
    # request a different URL than the running app does.
    filtered_query = Mydia.Indexers.CardigannFilters.apply_keywords_filters(query, definition)

    # Build template context
    context = %{
      keywords: filtered_query,
      config: build_default_config(definition),
      categories: [],
      settings: definition.settings || [],
      query: %{}
    }

    # Render the path template
    rendered_path =
      case Mydia.Indexers.CardigannTemplate.render(path_template, context) do
        {:ok, rendered} ->
          rendered

        {:error, _} ->
          String.replace(path_template, "{{ .Keywords }}", URI.encode(filtered_query))
      end

    # Add query parameters from inputs
    rendered_inputs =
      inputs
      |> Enum.map(fn {key, value} ->
        rendered_value =
          case Mydia.Indexers.CardigannTemplate.render(to_string(value), context,
                 url_encode: false
               ) do
            {:ok, v} -> v
            _ -> to_string(value)
          end

        {key, rendered_value}
      end)
      |> Enum.reject(fn {_k, v} -> v == "" end)

    if rendered_inputs != [] do
      query_string = URI.encode_query(rendered_inputs)
      "#{rendered_path}?#{query_string}"
    else
      rendered_path
    end
  end

  defp build_default_config(definition) do
    (definition.settings || [])
    |> Enum.reduce(%{}, fn setting, acc ->
      name = setting[:name] || setting["name"]
      default = setting[:default] || setting["default"]
      if name && default, do: Map.put(acc, name, to_string(default)), else: acc
    end)
  end

  defp capture_download_response(definition, response_body, query, _search_url) do
    if is_nil(definition.download) do
      :skipped
    else
      base_url =
        case definition.links do
          [url | _] when is_binary(url) -> url
          _ -> nil
        end

      if is_nil(base_url) do
        {:error, :no_base_url}
      else
        # Runtime filters the query through search.keywordsfilters before any
        # {{ .Keywords }} substitution, so capturing with the raw query would
        # pin a fixture to a context the running app never produces.
        template_context = %{
          keywords: Mydia.Indexers.CardigannFilters.apply_keywords_filters(query, definition),
          config: build_default_config(definition),
          categories: [],
          settings: definition.settings || [],
          query: %{}
        }

        response = %{status: 200, body: response_body}
        indexer_name = definition.name || definition.id

        case Mydia.Indexers.CardigannResultParser.parse_results(
               definition,
               response,
               indexer_name,
               template_context: template_context,
               base_url: base_url
             ) do
          {:ok, [first | _]} ->
            download_url = first.download_url

            if is_binary(download_url) and download_url != "" do
              absolute_url = absolutize_url(base_url, download_url)
              Mix.shell().info("  Capturing download page: #{absolute_url}")

              case Req.get(absolute_url,
                     headers: [{"user-agent", @user_agent}],
                     receive_timeout: 30_000,
                     redirect: true,
                     max_redirects: 5,
                     decode_body: false
                   ) do
                {:ok, %{status: 200, body: body}} when is_binary(body) ->
                  {:ok, body, absolute_url}

                {:ok, %{status: status}} ->
                  {:error, {:http_status, status}}

                {:error, reason} ->
                  {:error, reason}
              end
            else
              {:error, :no_download_url}
            end

          {:ok, []} ->
            {:error, :no_results}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  defp absolutize_url(_base, "http://" <> _ = url), do: url
  defp absolutize_url(_base, "https://" <> _ = url), do: url
  defp absolutize_url(_base, "magnet:" <> _ = url), do: url

  defp absolutize_url(base, path) when is_binary(path) do
    base |> String.trim_trailing("/") |> URI.merge(path) |> URI.to_string()
  end

  defp save_fixture(indexer_id, yaml_content, response_body, query, search_url, download_capture) do
    fixture_dir = Path.join(@fixtures_base, indexer_id)
    File.mkdir_p!(fixture_dir)

    # Save definition
    File.write!(Path.join(fixture_dir, "definition.yml"), yaml_content)

    # Detect response type and save accordingly
    response_type = detect_type(response_body)
    ext = if response_type == :json, do: "json", else: "html"
    File.write!(Path.join(fixture_dir, "response.#{ext}"), response_body)

    metadata =
      %{
        "indexer_id" => indexer_id,
        "query" => query,
        "search_url" => search_url,
        "response_type" => to_string(response_type),
        "response_size" => byte_size(response_body),
        "captured_at" => DateTime.to_iso8601(DateTime.utc_now())
      }
      |> maybe_add_download_metadata(download_capture)

    case download_capture do
      {:ok, download_body, download_source_url} ->
        File.write!(Path.join(fixture_dir, "download_response.html"), download_body)

        Mix.shell().info(
          "    download_response.html (#{byte_size(download_body)} bytes, from #{download_source_url})"
        )

      {:error, reason} ->
        Mix.shell().error("  Download page capture failed: #{inspect(reason)}")

      :skipped ->
        :ok
    end

    File.write!(
      Path.join(fixture_dir, "metadata.json"),
      Jason.encode!(metadata, pretty: true)
    )

    Mix.shell().info("  Saved fixture to #{fixture_dir}/")
    Mix.shell().info("    definition.yml (#{byte_size(yaml_content)} bytes)")
    Mix.shell().info("    response.#{ext} (#{byte_size(response_body)} bytes)")
    Mix.shell().info("    metadata.json")
  end

  defp maybe_add_download_metadata(metadata, {:ok, _body, download_source_url}) do
    Map.put(metadata, "download_source_url", download_source_url)
  end

  defp maybe_add_download_metadata(metadata, _download_capture), do: metadata

  defp save_definition_only(indexer_id, yaml_content, query) do
    fixture_dir = Path.join(@fixtures_base, indexer_id)
    File.mkdir_p!(fixture_dir)

    File.write!(Path.join(fixture_dir, "definition.yml"), yaml_content)

    metadata = %{
      "indexer_id" => indexer_id,
      "query" => query,
      "captured_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "error" => "response_capture_failed"
    }

    File.write!(
      Path.join(fixture_dir, "metadata.json"),
      Jason.encode!(metadata, pretty: true)
    )

    Mix.shell().info("  Saved definition only to #{fixture_dir}/ (response capture failed)")
  end

  defp detect_type(body) do
    trimmed = String.trim(body)

    if String.starts_with?(trimmed, "{") or String.starts_with?(trimmed, "[") do
      case Jason.decode(trimmed) do
        {:ok, _} -> :json
        _ -> :html
      end
    else
      :html
    end
  end
end
