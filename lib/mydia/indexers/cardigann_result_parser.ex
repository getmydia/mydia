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
  alias Mydia.Indexers.Cardigann.Result.{Context, Pipeline, Plan, Transform}
  alias Mydia.Indexers.CardigannDefinition.Parsed
  alias Mydia.Indexers.SearchResult
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

  @doc """
  Parses size with fallback to extracting from title.

  When the size field is empty or parses to 0, attempts to extract size
  from the title text using patterns like "(3.05Gb)" or "500MB".
  """
  @spec parse_size_with_title_fallback(String.t() | nil, String.t()) :: non_neg_integer()
  defdelegate parse_size_with_title_fallback(raw_size, title), to: Transform

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
  defdelegate parse_size(size_str), to: Transform

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
  defdelegate parse_date(date_str), to: Transform

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
