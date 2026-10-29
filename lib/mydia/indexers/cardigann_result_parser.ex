defmodule Mydia.Indexers.CardigannResultParser do
  @moduledoc """
  Parser for Cardigann search results from HTML, JSON or XML responses.

  The definition's `search.rows` and `search.fields` are compiled once per call
  into a `Mydia.Indexers.Cardigann.Result.Plan`, and
  `Mydia.Indexers.Cardigann.Result.Pipeline` runs it over the body through one
  shared field extractor and a small adapter per format:

  - HTML uses the lexbor-backed `Mydia.Indexers.Cardigann.Selector`, CSS
    selectors with `:contains()`
  - JSON uses JSONPath-style selectors (`Mydia.Indexers.Cardigann.JsonPath`)
  - XML (RSS, Torznab) uses SweetXml, with CSS child combinators and attribute
    predicates translated to XPath

  Every format honours `case`, `optional`/`default`, `text:` fields that read
  `.Result`, filters, `rows.after`/`rows.count` and row-level `andmatch`.
  `rows.missingAttributeEqualsNoResults: true` drops HTML rows that lack the
  configured row `attribute`.

  ## Cardigann Filters

  Applies transformation filters defined in the Cardigann spec:
  - `replace` - String replacement
  - `re_replace` - Regex replacement
  - `append` - Append string
  - `prepend` - Prepend string
  - `trim` - Trim whitespace
  - `split` - Split string and return part at index
  - `urldecode` - URL-decode strings
  - `regexp` - Regex extraction (first capture group)
  - `dateparse`/`timeparse` - Parse date with Go format layout
  - `timeago`/`reltime` - Parse relative time ("2 hours ago")
  - `fuzzytime` - Parse various date formats (Today, Yesterday, timestamps)
  - `tolower`/`toupper` - Case conversion
  - `urlencode` - URL-encode strings
  - `htmldecode` - Decode HTML entities
  - `querystring` - Extract URL query parameter value

  ## Examples

      # Parse HTML response
      definition = %Parsed{search: %{rows: %{selector: "tr.result"}, fields: ...}}
      response = %{status: 200, body: "<html>...</html>"}
      {:ok, results} = CardigannResultParser.parse_results(definition, response)

      # Parse JSON response
      definition = %Parsed{search: %{rows: %{selector: "$.results[*]"}, fields: ...}}
      response = %{status: 200, body: "{...}"}
      {:ok, results} = CardigannResultParser.parse_results(definition, response)
  """

  alias Mydia.Indexers.Cardigann.LinkResolver
  alias Mydia.Indexers.Cardigann.ParseStats
  alias Mydia.Indexers.Cardigann.Result.{Context, Pipeline, Plan}
  alias Mydia.Indexers.CardigannDefinition.Parsed
  alias Mydia.Indexers.SearchResult
  alias Mydia.Indexers.QualityParser
  alias Mydia.Indexers.CategoryMapping
  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.CardigannTemplate

  @type parse_result :: {:ok, [SearchResult.t()]} | {:error, Error.t()}
  @type http_response :: %{
          required(:status) => integer(),
          # Req decodes a JSON response into a map or a list; parse_body/4
          # handles all three shapes.
          required(:body) => String.t() | map() | list(),
          optional(:headers) => [{term(), term()}]
        }

  @doc """
  Parses search results from an HTTP response using Cardigann definition.

  Uses the response type the search path declares, and otherwise detects HTML,
  JSON or XML from the response body.

  ## Parameters

  - `definition` - Parsed Cardigann definition with search configuration
  - `response` - HTTP response with status and body
  - `indexer_name` - Name of the indexer for result attribution
  - `opts` - Optional keyword list with:
    - `:template_context` - Template context for rendering filter arguments

  ## Returns

  - `{:ok, results}` - List of SearchResult structs
  - `{:error, reason}` - Parsing error

  ## Examples

      iex> parse_results(definition, response, "1337x")
      {:ok, [%SearchResult{}, ...]}

      iex> parse_results(definition, response, "1337x", template_context: %{config: %{"sort" => "seeders"}})
      {:ok, [%SearchResult{}, ...]}
  """
  @spec parse_results(Parsed.t(), http_response(), String.t(), keyword()) :: parse_result()
  def parse_results(%Parsed{} = definition, response, indexer_name, opts \\ []) do
    with {:ok, results, _stats} <-
           parse_results_with_stats(definition, response, indexer_name, opts) do
      {:ok, results}
    end
  end

  @doc """
  Like `parse_results/4`, and also reports what happened to the matched rows.

  The `Mydia.Indexers.Cardigann.ParseStats` separates a search that matched
  nothing from one whose rows were all dropped for a missing title or download.
  """
  @spec parse_results_with_stats(Parsed.t(), http_response(), String.t(), keyword()) ::
          {:ok, [SearchResult.t()], ParseStats.t()} | {:error, Error.t()}
  def parse_results_with_stats(%Parsed{} = definition, response, indexer_name, opts \\ []) do
    template_context = Keyword.get(opts, :template_context, %{})

    ctx = %Context{
      indexer_name: indexer_name,
      template_context: template_context,
      base_url: LinkResolver.base(Keyword.get(opts, :base_url, ""), opts, template_context),
      category_mappings: get_in(definition.capabilities, [:categorymappings]) || [],
      search: definition.search || %{}
    }

    parse_body(response.body, definition, ctx, opts)
  end

  # Guard against nil or non-string bodies
  defp parse_body(nil, _definition, _ctx, _opts) do
    {:error, Error.search_failed("Empty response body")}
  end

  # Req auto-decoded JSON. apibay.org (The Pirate Bay) answers with a
  # top-level array, which decodes to a list, not a map.
  defp parse_body(body, definition, ctx, opts) when is_map(body) or is_list(body) do
    run(definition, body, ctx, opts, fn _declared -> :json end)
  end

  defp parse_body(body, _definition, _ctx, _opts) when not is_binary(body) do
    {:error, Error.search_failed("Invalid response body type: #{inspect(body)}")}
  end

  defp parse_body(body, definition, ctx, opts) do
    if String.trim(body) == "" do
      {:ok, [], %ParseStats{}}
    else
      run(definition, body, ctx, opts, &(&1 || detect_response_type(body)))
    end
  end

  # `pick_format` gets the response type the search path declares (nil when
  # it declares none) and returns the one to parse with.
  defp run(definition, body, ctx, opts, pick_format) do
    with {:ok, plan} <- Plan.compile(definition, ctx.template_context, opts) do
      Pipeline.run(%{plan | format: pick_format.(plan.format)}, body, ctx)
    end
  end

  @doc false
  @spec html_parse_failure(Exception.t(), String.t()) :: {:error, Error.t()}
  def html_parse_failure(error, indexer_name),
    do: Pipeline.parse_failure(error, :html, indexer_name)

  @doc """
  Applies Cardigann filters to a field value.

  Filters are applied in sequence, with each filter transforming
  the value before passing to the next filter. Filter arguments
  containing Go template syntax will be rendered using the provided
  template context before application.

  ## Supported Filters

  - `replace` - String replacement: `{name: "replace", args: ["old", "new"]}`
  - `re_replace` - Regex replacement: `{name: "re_replace", args: ["pattern", "replacement"]}`
  - `append` - Append string: `{name: "append", args: ["suffix"]}`
  - `prepend` - Prepend string: `{name: "prepend", args: ["prefix"]}`
  - `trim` - Trim whitespace: `{name: "trim"}`
  - `dateparse` - Parse date: `{name: "dateparse", args: ["format"]}`

  ## Examples

      iex> apply_filters("  test  ", [%{name: "trim"}], %{})
      {:ok, "test"}

      iex> apply_filters("1.5 GB", [%{name: "replace", args: [" GB", ""]}], %{})
      {:ok, "1.5"}

      iex> apply_filters("text", [%{name: "append", args: ["{{ if .Config.flag }} suffix{{ else }}{{ end }}"]}], %{config: %{"flag" => true}})
      {:ok, "text suffix"}
  """
  @spec apply_filters(String.t(), list(), map()) :: {:ok, String.t()}
  def apply_filters(value, [], _template_context), do: {:ok, value}

  def apply_filters(value, [filter | rest], template_context) do
    # Render templates in filter arguments
    rendered_filter = render_filter_templates(filter, template_context)

    # apply_single_filter/2 delegates to CardigannFilters.apply/2, whose spec
    # guarantees {:ok, _}, so there is no error case to branch on here.
    {:ok, new_value} = apply_single_filter(value, rendered_filter)
    apply_filters(new_value, rest, template_context)
  end

  # Backward compatibility - allow calling without template_context
  def apply_filters(value, filters) when is_list(filters) do
    apply_filters(value, filters, %{})
  end

  # Renders Go templates in filter arguments using the provided template context
  defp render_filter_templates(filter, template_context) when is_map(filter) do
    # Get args from filter (support both atom and string keys)
    args = Map.get(filter, :args) || Map.get(filter, "args")
    args_key = if Map.has_key?(filter, :args), do: :args, else: "args"

    case args do
      nil ->
        filter

      args when is_list(args) ->
        # Render each arg that contains template syntax (if template_context available)
        rendered_args =
          if template_context == %{} or template_context == nil do
            args
          else
            Enum.map(args, fn arg ->
              render_template_in_string(arg, template_context)
            end)
          end

        Map.put(filter, args_key, rendered_args)

      args when is_binary(args) ->
        # Single string arg - render template (if context available) and wrap in list for consistency
        rendered_arg =
          if template_context == %{} or template_context == nil do
            args
          else
            render_template_in_string(args, template_context)
          end

        Map.put(filter, args_key, [rendered_arg])

      _ ->
        filter
    end
  end

  defp render_filter_templates(filter, _template_context), do: filter

  # Helper to render template in a string if it contains template syntax
  defp render_template_in_string(value, template_context) when is_binary(value) do
    if String.contains?(value, "{{") do
      case CardigannTemplate.render(value, template_context, url_encode: false) do
        {:ok, rendered} -> rendered
        {:error, _} -> value
      end
    else
      value
    end
  end

  defp render_template_in_string(value, _template_context), do: value

  # Delegate all filter application to the CardigannFilters module
  defp apply_single_filter(value, filter) do
    Mydia.Indexers.CardigannFilters.apply(filter, value)
  end

  # Result Transformation

  @doc false
  # Public only so Result.Pipeline can reach it until the transform moves to
  # its own module.
  @spec transform_to_search_results([map()], String.t(), String.t(), list()) ::
          [SearchResult.t()]
  def transform_to_search_results(parsed_rows, indexer_name, base_url, category_mappings) do
    parsed_rows
    |> Enum.map(fn row ->
      transform_to_search_result(row, indexer_name, base_url, category_mappings)
    end)
    |> Enum.filter(&(&1 != nil))
  end

  defp transform_to_search_result(row, indexer_name, base_url, category_mappings) do
    raw_size = get_field(row, "size", "0")

    with {:ok, title} <- get_required_field(row, "title"),
         {:ok, download_url} <- get_download_or_magnet(row, title),
         size <- parse_size_with_title_fallback(raw_size, title),
         seeders <- parse_integer(get_field(row, "seeders", "0")),
         leechers <- parse_integer(get_field(row, "leechers", "0")) do
      # Parse quality from title
      quality = QualityParser.parse(title)

      # Resolve relative URLs to absolute
      resolved_download_url = LinkResolver.resolve(download_url, base_url)
      resolved_info_url = LinkResolver.resolve(get_field(row, "details"), base_url)

      # Detect download protocol from URL
      download_protocol = detect_download_protocol(resolved_download_url)

      # Map site-specific category to Torznab category
      raw_category = get_field(row, "category")
      torznab_category = map_category(raw_category, category_mappings)

      # Build SearchResult
      %SearchResult{
        title: title,
        size: size,
        seeders: seeders,
        leechers: leechers,
        download_url: resolved_download_url,
        info_url: resolved_info_url,
        indexer: indexer_name,
        category: torznab_category,
        published_at: parse_date(get_field(row, "date")),
        quality: quality,
        tmdb_id: parse_integer(get_field(row, "tmdbid")),
        imdb_id: get_field(row, "imdbid"),
        download_protocol: download_protocol
      }
    else
      _ -> nil
    end
  end

  # Maps a site-specific category to a Torznab category ID
  defp map_category(nil, _category_mappings), do: nil
  defp map_category("", _category_mappings), do: nil

  defp map_category(raw_category, category_mappings)
       when is_list(category_mappings) and category_mappings != [] do
    # Try to map using the category mappings from the definition
    case CategoryMapping.map_site_category_to_torznab(raw_category, category_mappings) do
      nil ->
        # Fallback: check if raw_category is already a Torznab ID
        parse_integer(raw_category)

      torznab_id ->
        torznab_id
    end
  end

  defp map_category(raw_category, _category_mappings) do
    # No mappings available, just parse as integer (might already be Torznab ID)
    parse_integer(raw_category)
  end

  # Resolve a URL relative to a base URL
  # Gets download URL from 'infohash' (preferred) or 'download' field.
  # Infohash is preferred because some indexers (e.g. YTS) return HTML
  # instead of a .torrent file at the download URL.
  defp get_download_or_magnet(row, title) do
    alias Mydia.Downloads.TorrentHash

    case get_required_field(row, "infohash") do
      {:ok, hash} when byte_size(hash) >= 32 ->
        case TorrentHash.build_magnet(hash, title) do
          nil -> try_download_field(row)
          magnet -> {:ok, magnet}
        end

      _ ->
        try_download_field(row)
    end
  end

  defp try_download_field(row) do
    case get_required_field(row, "download") do
      {:ok, url} -> {:ok, url}
      {:error, _} -> {:error, :no_download_or_infohash}
    end
  end

  defp get_required_field(row, field) do
    # Check both string and atom keys since parser may use either
    value = Map.get(row, field) || Map.get(row, String.to_atom(field))

    case value do
      nil -> {:error, :missing_field}
      "" -> {:error, :empty_field}
      value -> {:ok, value}
    end
  end

  defp get_field(row, field, default \\ nil) do
    # Check both string and atom keys since parser may use either
    Map.get(row, field) || Map.get(row, String.to_atom(field), default)
  end

  @doc """
  Parses size with fallback to extracting from title.

  When the size field is empty or parses to 0, attempts to extract size
  from the title text using patterns like "(3.05Gb)" or "500MB".
  """
  @spec parse_size_with_title_fallback(String.t() | nil, String.t()) :: non_neg_integer()
  def parse_size_with_title_fallback(raw_size, title) do
    size = parse_size(raw_size)

    if size == 0 do
      # Try to extract size from title
      extract_size_from_text(title)
    else
      size
    end
  end

  # Extracts size from text containing embedded size like "(3.05Gb)" or "500MB"
  defp extract_size_from_text(text) when is_binary(text) do
    # Match patterns like (3.05Gb), 500MB, 1.2 GB, etc.
    case Regex.run(~r/([\d.]+)\s*(gb|gib|mb|mib|kb|kib|tb|tib)/i, text) do
      [_, num_str, unit] ->
        case Float.parse(num_str) do
          {num, _} ->
            multiplier = size_unit_multiplier(String.downcase(unit))
            trunc(num * multiplier)

          :error ->
            0
        end

      nil ->
        0
    end
  end

  defp extract_size_from_text(_), do: 0

  defp size_unit_multiplier("tb"), do: 1024 * 1024 * 1024 * 1024
  defp size_unit_multiplier("tib"), do: 1024 * 1024 * 1024 * 1024
  defp size_unit_multiplier("gb"), do: 1024 * 1024 * 1024
  defp size_unit_multiplier("gib"), do: 1024 * 1024 * 1024
  defp size_unit_multiplier("mb"), do: 1024 * 1024
  defp size_unit_multiplier("mib"), do: 1024 * 1024
  defp size_unit_multiplier("kb"), do: 1024
  defp size_unit_multiplier("kib"), do: 1024
  defp size_unit_multiplier(_), do: 1

  @doc """
  Parses size strings to bytes.

  Supports various formats (case-insensitive):
  - "1.5 GB" → 1_610_612_736 bytes
  - "500 MB" → 524_288_000 bytes
  - "1024 KB" → 1_048_576 bytes
  - "1024" → 1024 bytes
  - "3.05Gb" → (lowercase units supported)

  ## Examples

      iex> parse_size("1.5 GB")
      1_610_612_736

      iex> parse_size("500 MB")
      524_288_000
  """
  @spec parse_size(String.t() | nil) :: non_neg_integer()
  def parse_size(nil), do: 0
  def parse_size(""), do: 0

  def parse_size(size_str) when is_binary(size_str) do
    size_str = String.trim(size_str)
    size_str_lower = String.downcase(size_str)

    cond do
      String.contains?(size_str_lower, "gb") || String.contains?(size_str_lower, "gib") ->
        parse_size_value(size_str, 1024 * 1024 * 1024)

      String.contains?(size_str_lower, "mb") || String.contains?(size_str_lower, "mib") ->
        parse_size_value(size_str, 1024 * 1024)

      String.contains?(size_str_lower, "kb") || String.contains?(size_str_lower, "kib") ->
        parse_size_value(size_str, 1024)

      String.contains?(size_str_lower, "tb") || String.contains?(size_str_lower, "tib") ->
        parse_size_value(size_str, 1024 * 1024 * 1024 * 1024)

      true ->
        # Assume it's already in bytes
        parse_integer(size_str)
    end
  end

  defp parse_size_value(size_str, multiplier) do
    # Extract numeric value from string, looking for patterns like "3.05Gb" or "500 MB"
    # First try to find a number immediately before or after the unit
    numeric_part =
      case Regex.run(~r/([\d.]+)\s*(?:gb|gib|mb|mib|kb|kib|tb|tib)/i, size_str) do
        [_, num] ->
          num

        nil ->
          # Fallback: just extract all digits and periods
          size_str
          |> String.replace(~r/[^\d.]/, "")
          |> String.trim()
      end

    case Float.parse(numeric_part) do
      {value, _} -> trunc(value * multiplier)
      :error -> 0
    end
  end

  defp parse_integer(nil), do: 0
  defp parse_integer(""), do: 0

  defp parse_integer(str) when is_binary(str) do
    # Remove any non-digit characters
    clean_str = String.replace(str, ~r/[^\d]/, "")

    case Integer.parse(clean_str) do
      {num, _} -> num
      :error -> 0
    end
  end

  defp parse_integer(num) when is_integer(num), do: num
  defp parse_integer(_), do: 0

  @doc """
  Parses date strings to DateTime.

  Attempts to parse various date formats:
  - ISO 8601: "2024-01-15T12:30:00Z"
  - Relative: "2 hours ago", "yesterday"
  - Custom formats based on common patterns

  ## Examples

      iex> parse_date("2024-01-15T12:30:00Z")
      ~U[2024-01-15 12:30:00Z]

      iex> parse_date(nil)
      nil
  """
  @spec parse_date(String.t() | nil) :: DateTime.t() | nil
  def parse_date(nil), do: nil
  def parse_date(""), do: nil

  def parse_date(date_str) when is_binary(date_str) do
    # Try ISO 8601 format first
    case DateTime.from_iso8601(date_str) do
      {:ok, datetime, _offset} ->
        datetime

      _ ->
        # Try other common formats using Timex
        case Timex.parse(date_str, "{ISO:Extended}") do
          {:ok, datetime} -> datetime
          _ -> nil
        end
    end
  rescue
    _ -> nil
  end

  # Download Protocol Detection
  # Detects protocol from URL: magnet/.torrent → :torrent, .nzb → :nzb
  # Defaults to :torrent as most Cardigann indexers are torrent sites
  defp detect_download_protocol(url) when is_binary(url) do
    cond do
      String.starts_with?(url, "magnet:") -> :torrent
      String.contains?(url, ".torrent") -> :torrent
      String.contains?(url, ".nzb") -> :nzb
      String.contains?(url, "nzb") -> :nzb
      true -> :torrent
    end
  end

  defp detect_download_protocol(_), do: :torrent

  # Response Type Detection

  # Sniffing only decides when the definition declares no `response.type`,
  # because RSS and HTML both start with `<`.
  defp detect_response_type(body) when is_binary(body) do
    trimmed = String.trim(body)

    cond do
      # Check if it looks like JSON (starts with { or [)
      String.starts_with?(trimmed, "{") || String.starts_with?(trimmed, "[") ->
        # Verify it's actually valid JSON before treating as JSON
        case Jason.decode(trimmed) do
          {:ok, _} -> :json
          {:error, _} -> :html
        end

      String.starts_with?(trimmed, "<") ->
        cond do
          String.starts_with?(trimmed, "<?xml") -> :xml
          String.match?(trimmed, ~r/^<rss[\s>]/i) -> :xml
          String.match?(trimmed, ~r/^<torrents[\s>]/i) -> :xml
          true -> :html
        end

      true ->
        # Default to HTML for ambiguous cases
        :html
    end
  end
end
