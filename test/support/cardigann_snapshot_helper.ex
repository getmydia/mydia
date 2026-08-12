defmodule Mydia.CardigannSnapshotHelper do
  @moduledoc """
  Helper for running snapshot tests against Cardigann indexer definitions.

  Loads a YAML definition and saved HTML/JSON fixture, parses results through
  the Cardigann engine, and asserts on the output.

  ## Usage

      use ExUnit.Case
      import Mydia.CardigannSnapshotHelper

      test "1337x parses correctly" do
        run_snapshot("test/fixtures/cardigann/1337x", min_results: 10, assertions: fn results ->
          first = hd(results)
          assert first.title != ""
          assert first.seeders >= 0
        end)
      end
  """

  alias Mydia.Indexers.CardigannParser
  alias Mydia.Indexers.CardigannResultParser
  alias Mydia.Downloads.TorrentHash

  @whole_document_selectors [":root", "", nil]

  @doc """
  Runs a snapshot test for a fixture directory.

  The directory must contain:
  - `definition.yml` - The Cardigann YAML definition
  - `response.html` or `response.json` - The saved search response

  Optionally:
  - `metadata.json` - Query metadata (keywords, expected count, etc.)

  ## Options

  - `:min_results` - Minimum expected result count (default: 1)
  - `:assertions` - Function receiving the results list for custom assertions
  - `:template_context` - Template context for rendering (default: builds from metadata)
  """
  def run_snapshot(fixture_dir, opts \\ []) do
    min_results = Keyword.get(opts, :min_results, 1)
    assertions_fn = Keyword.get(opts, :assertions)
    extra_context = Keyword.get(opts, :template_context)

    # Load definition
    definition_path = Path.join(fixture_dir, "definition.yml")

    unless File.exists?(definition_path) do
      raise "Missing definition file: #{definition_path}"
    end

    yaml_content = File.read!(definition_path)

    {:ok, definition} = CardigannParser.parse_definition(yaml_content)

    # Load response fixture
    {response_body, _type} = load_response_fixture(fixture_dir)

    # Load metadata if available
    metadata = load_metadata(fixture_dir)

    # Build template context
    template_context =
      extra_context ||
        build_template_context(metadata, definition)

    # Build base URL from definition
    base_url =
      case definition.links do
        [url | _] when is_binary(url) -> url
        _ -> ""
      end

    indexer_name = definition.name || definition.id

    # Parse results
    response = %{status: 200, body: response_body}

    result =
      CardigannResultParser.parse_results(definition, response, indexer_name,
        template_context: template_context,
        base_url: base_url
      )

    case result do
      {:ok, results} ->
        # Assert minimum result count
        if length(results) < min_results do
          raise ExUnit.AssertionError,
            message:
              "Expected at least #{min_results} results from #{indexer_name}, got #{length(results)}"
        end

        # Run custom assertions if provided
        if assertions_fn do
          assertions_fn.(results)
        end

        {:ok, results}

      {:error, error} ->
        raise ExUnit.AssertionError,
          message: "Parsing failed for #{indexer_name}: #{inspect(error)}"
    end
  end

  @doc """
  Runs a download-block snapshot for a fixture directory.

  Requires `definition.yml` and `download_response.html`. Asserts the
  definition's download block resolves the captured page to a magnet or a
  download URL.
  """
  def run_download_snapshot(fixture_dir, opts \\ []) do
    yaml = File.read!(Path.join(fixture_dir, "definition.yml"))
    {:ok, definition} = CardigannParser.parse_definition(yaml)
    page = File.read!(Path.join(fixture_dir, "download_response.html"))

    expect = Keyword.get(opts, :expect, :magnet)

    block = definition.download

    if is_nil(block) do
      raise ExUnit.AssertionError,
        message: "fixture #{fixture_dir} has no download block"
    end

    value =
      case resolve_download_value(block, page) do
        {:ok, value} -> value
        :no_match -> nil
      end

    case expect do
      :magnet ->
        unless value && String.starts_with?(value, "magnet:") do
          raise ExUnit.AssertionError,
            message: "expected magnet link from #{fixture_dir}, got #{inspect(value)}"
        end

      :url ->
        unless value && value != "" do
          raise ExUnit.AssertionError,
            message: "expected download URL from #{fixture_dir}, got #{inspect(value)}"
        end
    end

    {:ok, value}
  end

  defp resolve_download_value(block, page) do
    selectors = Map.get(block, :selectors) || []

    cond do
      selectors != [] ->
        resolve_selector_value(selectors, page)

      usable_infohash?(Map.get(block, :infohash)) ->
        resolve_infohash_value(Map.get(block, :infohash), page)

      true ->
        :no_match
    end
  end

  defp usable_infohash?(%{hash: hash}) when is_map(hash), do: true
  defp usable_infohash?(_), do: false

  defp resolve_selector_value(selectors, page) do
    document = Floki.parse_document!(page)

    selectors
    |> List.wrap()
    |> Enum.find_value(fn config ->
      case extract_selector_value(document, config, %{}) do
        {:ok, v} when is_binary(v) and v != "" -> v
        _ -> nil
      end
    end)
    |> case do
      nil -> :no_match
      value -> {:ok, value}
    end
  end

  defp resolve_infohash_value(infohash, page) do
    variables = %{}

    with {:ok, hash} <- match_download_selector(page, Map.get(infohash, :hash), variables, "hash"),
         {:ok, title} <- match_download_title(page, Map.get(infohash, :title), variables) do
      case TorrentHash.build_magnet(hash, title) do
        nil -> :no_match
        magnet -> {:ok, magnet}
      end
    else
      _ -> :no_match
    end
  end

  defp match_download_title(_page, nil, _variables), do: {:ok, nil}

  defp match_download_title(page, selector, variables) do
    case match_download_selector(page, selector, variables, "title") do
      {:ok, title} -> {:ok, title}
      {:error, _} -> {:ok, nil}
    end
  end

  defp match_download_selector(_page, nil, _variables, label) do
    {:error, "no #{label} selector configured"}
  end

  defp match_download_selector(page, selector, variables, label) do
    filters = Map.get(selector, :filters) || []

    with {:ok, selector_text} <- render_template(Map.get(selector, :selector), variables),
         {:ok, raw} <-
           extract_from_page(page, selector_text, Map.get(selector, :attribute), label),
         {:ok, value} <- CardigannResultParser.apply_filters(raw, filters, variables) do
      case String.trim(value) do
        "" -> {:error, "#{label} selector matched an empty value"}
        trimmed -> {:ok, trimmed}
      end
    end
  end

  defp extract_selector_value(document, config, variables) do
    filters = Map.get(config, :filters) || []

    with {:ok, selector_text} <- render_template(Map.get(config, :selector), variables),
         {:ok, raw} <- extract_from_document(document, selector_text, Map.get(config, :attribute)),
         {:ok, value} <- CardigannResultParser.apply_filters(raw, filters, variables) do
      trimmed = String.trim(value)
      if trimmed == "", do: {:error, :empty}, else: {:ok, trimmed}
    end
  end

  defp extract_from_page(page, selector_text, _attribute, _label)
       when selector_text in @whole_document_selectors do
    {:ok, page}
  end

  defp extract_from_page(page, selector_text, attribute, label) do
    with {:ok, document} <- Floki.parse_document(page) do
      extract_from_document(document, selector_text, attribute)
    else
      {:error, reason} -> {:error, "could not parse #{label} response: #{inspect(reason)}"}
    end
  end

  defp extract_from_document(document, selector_text, _attribute)
       when selector_text in @whole_document_selectors do
    {:ok, Floki.raw_html(document)}
  end

  defp extract_from_document(document, selector_text, attribute) do
    case Floki.find(document, selector_text) do
      [] ->
        {:error, :no_match}

      elements ->
        value =
          case attribute do
            nil ->
              elements |> Floki.text() |> String.trim()

            attr ->
              elements |> Floki.attribute(attr) |> List.first() |> Kernel.||("") |> String.trim()
          end

        {:ok, value}
    end
  end

  defp render_template(nil, _variables), do: {:ok, ""}

  defp render_template(template, variables) when is_binary(template) do
    Mydia.Indexers.CardigannTemplate.render(template, variables, url_encode: false)
  end

  defp render_template(value, _variables), do: {:ok, to_string(value)}

  @doc """
  Lists all available fixture directories.
  """
  def list_fixture_dirs(base_path \\ "test/fixtures/cardigann") do
    if File.dir?(base_path) do
      base_path
      |> File.ls!()
      |> Enum.map(&Path.join(base_path, &1))
      |> Enum.filter(fn dir ->
        File.dir?(dir) and File.exists?(Path.join(dir, "definition.yml"))
      end)
      |> Enum.sort()
    else
      []
    end
  end

  @doc """
  Validates basic field expectations on a list of search results.
  """
  def assert_basic_fields(results) do
    for result <- results do
      # Title should be non-empty
      assert_field_present(result, :title, "title")

      # Download URL should be non-empty
      assert_field_present(result, :download_url, "download_url")

      # Seeders should be non-negative
      if result.seeders do
        unless result.seeders >= 0 do
          raise ExUnit.AssertionError,
            message: "Expected seeders >= 0, got #{result.seeders} for '#{result.title}'"
        end
      end
    end
  end

  defp assert_field_present(result, field, name) do
    value = Map.get(result, field)

    if is_nil(value) or value == "" do
      raise ExUnit.AssertionError,
        message: "Expected #{name} to be present, got #{inspect(value)}"
    end
  end

  defp load_response_fixture(fixture_dir) do
    html_path = Path.join(fixture_dir, "response.html")
    json_path = Path.join(fixture_dir, "response.json")

    cond do
      File.exists?(html_path) -> {File.read!(html_path), :html}
      File.exists?(json_path) -> {File.read!(json_path), :json}
      true -> raise "No response fixture found in #{fixture_dir}"
    end
  end

  defp load_metadata(fixture_dir) do
    metadata_path = Path.join(fixture_dir, "metadata.json")

    if File.exists?(metadata_path) do
      case Jason.decode(File.read!(metadata_path)) do
        {:ok, metadata} -> metadata
        _ -> %{}
      end
    else
      %{}
    end
  end

  defp build_template_context(metadata, definition) do
    keywords = Map.get(metadata, "query", "test")

    # Build config from definition settings defaults
    config =
      (definition.settings || [])
      |> Enum.reduce(%{}, fn setting, acc ->
        name = setting[:name] || setting["name"]
        default = setting[:default] || setting["default"]
        if name && default, do: Map.put(acc, name, to_string(default)), else: acc
      end)

    %{
      keywords: keywords,
      config: config,
      categories: [],
      settings: definition.settings || [],
      query: %{}
    }
  end
end
