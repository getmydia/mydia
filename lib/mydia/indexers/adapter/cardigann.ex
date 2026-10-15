defmodule Mydia.Indexers.Adapter.Cardigann do
  @moduledoc """
  Cardigann indexer adapter for native Prowlarr/Cardigann definition support.

  This adapter integrates Cardigann search engine with the existing Indexers
  module, allowing direct execution of searches using Cardigann YAML definitions
  without requiring external Prowlarr or Jackett instances.

  ## Configuration

  The adapter expects a config map with the following structure:

      %{
        type: :cardigann,
        name: "Indexer Name",
        indexer_id: "1337x",
        enabled: true,
        user_settings: %{
          # User-provided credentials if needed for private indexers
          username: "user",
          password: "pass",
          # Or API key
          api_key: "..."
        }
      }

  ## Example Usage

      config = %{
        type: :cardigann,
        name: "1337x",
        indexer_id: "1337x",
        enabled: true
      }

      {:ok, results} = Cardigann.search(config, "Ubuntu 22.04")

  ## Integration

  - Fetches definition from database using `indexer_id`
  - Parses definition using `CardigannParser`
  - Executes search using `CardigannSearchEngine`
  - Parses results using `CardigannResultParser`
  - Returns normalized `SearchResult` structs

  ## Authentication

  For private indexers requiring authentication:
  - Credentials stored in `user_settings` map
  - Login handled by `CardigannSearchSession` (future implementation)
  - Cookies managed per-user, per-indexer
  """

  @behaviour Mydia.Indexers.Adapter

  alias Mydia.Indexers.{CardigannParser, CardigannSearchEngine, CardigannResultParser}
  alias Mydia.Indexers.{CardigannDefinition, CardigannFeatureFlags}
  alias Mydia.Indexers.Cardigann.SearchPages
  alias Mydia.Indexers.Cardigann.SessionManager
  alias Mydia.Indexers.CardigannHealthCheck
  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.Cardigann.AdapterSupport

  import AdapterSupport,
    only: [
      apply_search_filters: 2,
      build_flaresolverr_opts: 1,
      fetch_definition: 1,
      handle_flaresolverr_result: 2
    ]

  require Logger

  @impl true
  def test_connection(config) do
    if CardigannFeatureFlags.enabled?() do
      with {:ok, definition} <- fetch_definition(config),
           {:ok, parsed} <- parse_definition(definition),
           :ok <- test_indexer_reachable(parsed, definition) do
        {:ok,
         %{
           name: parsed.name,
           type: parsed.type,
           language: parsed.language,
           indexer_id: parsed.id
         }}
      end
    else
      Logger.debug("Cardigann test connection skipped - feature disabled")
      {:error, Error.invalid_config("Cardigann feature is disabled")}
    end
  end

  @impl true
  def search(config, query, opts \\ []) do
    if CardigannFeatureFlags.enabled?() do
      with {:ok, definition} <- fetch_definition(config),
           {:ok, parsed} <- parse_definition(definition),
           {:ok, search_opts} <- build_search_opts(parsed, definition, query, opts),
           {:ok, [first_path | later_paths]} <-
             CardigannSearchEngine.matching_search_paths(parsed, search_opts),
           search_opts <- Keyword.put(search_opts, :paging_deadline, paging_deadline()),
           flaresolverr_opts <- build_flaresolverr_opts(definition),
           # Only page 1 runs inside the session, so LoggedOut judges page 1 and
           # a relogin retries page 1 alone.
           {:ok, response, {flaresolverr_result, user_config}} <-
             SessionManager.with_session(parsed, definition, fn user_config ->
               execute_search_with_flaresolverr(
                 parsed,
                 Keyword.put(search_opts, :search_path, first_path),
                 user_config,
                 flaresolverr_opts
               )
             end) do
        parse = page_parser(parsed, definition, config, search_opts)

        with {:ok, first_rows} <- parse.(first_path, response) do
          handle_flaresolverr_result(definition, flaresolverr_result)

          rows =
            collect_later_pages(
              first_rows,
              {parsed, later_paths, search_opts, user_config, flaresolverr_opts},
              response,
              parse
            )

          {:ok, apply_search_filters(rows, opts)}
        end
      end
    else
      Logger.debug("Cardigann search skipped - feature disabled")
      {:ok, []}
    end
  end

  # Later pages stop once this much time has passed since the search began, so a
  # slow site cannot push the whole search past its caller's deadline.
  @paging_budget_ms 15_000

  defp paging_deadline, do: System.monotonic_time(:millisecond) + @paging_budget_ms

  # An empty page 1 ends the search; otherwise the later pages are best effort.
  defp collect_later_pages([], _page_args, _response, _parse), do: []

  defp collect_later_pages(
         first_rows,
         {parsed, later_paths, search_opts, user_config, flaresolverr_opts},
         response,
         parse
       ) do
    later_rows =
      SearchPages.collect(
        parsed,
        later_paths,
        search_opts,
        user_config,
        flaresolverr_opts,
        Map.get(response, :base_url),
        parse
      )

    SearchPages.dedupe(first_rows ++ later_rows)
  end

  # Each page is parsed with its own search path, so a path's declared response
  # type applies to that page only.
  defp page_parser(parsed, definition, config, search_opts) do
    template_context = build_template_context_for_parsing(parsed, search_opts)

    base_url =
      definition.active_link || List.first(Mydia.Indexers.Cardigann.Links.candidates(parsed)) ||
        ""

    fn path, response ->
      CardigannResultParser.parse_results(parsed, response, config.name,
        template_context: template_context,
        base_url: base_url,
        search_path: path
      )
    end
  end

  # Execute search and normalize the result to always include flaresolverr_result
  defp execute_search_with_flaresolverr(parsed, search_opts, user_config, flaresolverr_opts) do
    # FlareSolverr clearance lives in FlareSolverr.ClearanceCache, keyed by
    # host. It used to be written to cardigann_search_sessions, the table and
    # "latest row per definition" query the login session store uses,
    # so a solve could replace a login session.
    case CardigannSearchEngine.execute_search(
           parsed,
           search_opts,
           user_config,
           flaresolverr_opts
         ) do
      {:ok, response, markers} ->
        {:ok, response, {{:flaresolverr_markers, markers}, user_config}}

      {:ok, response} ->
        {:ok, response, {:no_flaresolverr, user_config}}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def get_capabilities(config) do
    with {:ok, definition} <- fetch_definition(config),
         {:ok, parsed} <- parse_definition(definition) do
      capabilities = build_capabilities_response(parsed)
      {:ok, capabilities}
    end
  end

  ## Private Functions

  defp parse_definition(%CardigannDefinition{definition: yaml_string}) do
    case CardigannParser.parse_definition(yaml_string) do
      {:ok, parsed} ->
        {:ok, parsed}

      {:error, reason} ->
        Logger.error("Failed to parse Cardigann definition: #{inspect(reason)}")
        {:error, Error.search_failed("Invalid definition: #{inspect(reason)}")}
    end
  end

  # Reaching the homepage is not the same as being able to search, and treating
  # it as such is what let 1337x, EZTV, KickassTorrents, YTS and The Pirate Bay
  # all report a successful connection test while every search failed.
  #
  # The probe builds the same authenticated session a real search gets from
  # SessionManager.user_config/2. Without it, a private indexer with a stored
  # session (or one whose login the definition's settings can satisfy) probed
  # unauthenticated and reported a false connection
  # failure while its real, authenticated searches kept succeeding - the exact
  # false red this task exists to eliminate, mirror image of the false green
  # above.
  #
  # The template-context :config still comes from definition.config alone,
  # never from the adapter config's :user_settings or a nested :config key:
  # build_search_opts/4 (the real search path) does the same, so sourcing it
  # any other way here would let the probe render {{ .Config.* }} differently
  # than a real search does, either dropping settings that do work or
  # reporting settings that don't. build_probe_user_config/2 layers the
  # session's cookies on top of definition.config instead of
  # replacing it, so both stay true at once.
  defp test_indexer_reachable(parsed, %CardigannDefinition{} = definition) do
    with {:ok, user_config} <- build_probe_user_config(parsed, definition) do
      case CardigannHealthCheck.probe_candidates(parsed, user_config) do
        {:ok, url, _status} ->
          case CardigannHealthCheck.probe_search(parsed, user_config, url) do
            {:ok, _count, _served_by} ->
              :ok

            {:cloudflare, _message} ->
              {:error,
               Error.connection_failed(
                 "Cloudflare protection detected on #{url}. Enable FlareSolverr for this indexer."
               )}

            {:error, message} ->
              {:error, Error.search_failed("Reached #{url} but the search failed: #{message}")}
          end

        {:error, status} when map_size(status) == 0 ->
          {:error, Error.invalid_config("No base URL configured in definition")}

        {:error, _status} ->
          {:error, Error.connection_failed("No reachable base URL")}
      end
    end
  end

  # Builds the same authenticated session a real search gets from
  # SessionManager.user_config/2 (a stored session's cookies, or a fresh login
  # when the definition requires one), then layers it onto definition.config.
  # A genuine login failure surfaces as a connection failure here, same as it
  # would surface as a search failure for a real search; a definition with no
  # login block gets an empty session and is not penalized for it.
  defp build_probe_user_config(parsed, %CardigannDefinition{} = definition) do
    with {:ok, session_user_config} <- SessionManager.user_config(parsed, definition) do
      {:ok, Map.merge(definition.config || %{}, session_user_config)}
    end
  end

  defp build_search_opts(parsed, definition, query, opts) do
    search_opts = [
      query: query,
      categories: Keyword.get(opts, :categories, []),
      season: Keyword.get(opts, :season),
      episode: Keyword.get(opts, :episode),
      imdb_id: Keyword.get(opts, :imdb_id),
      tmdb_id: Keyword.get(opts, :tmdb_id),
      tvdb_id: Keyword.get(opts, :tvdb_id),
      config: definition.config || %{},
      settings: parsed.settings,
      base_url: definition.active_link,
      on_promote: &AdapterSupport.promote_active_link(parsed, definition, &1)
    ]

    {:ok, search_opts}
  end

  defp build_capabilities_response(parsed) do
    # Extract categories from the definition
    categories = extract_categories(parsed.capabilities)

    # Build capabilities map compatible with Adapter behaviour
    %{
      searching: %{
        search: %{available: true, supported_params: ["q"]},
        tv_search: %{
          available: has_tv_search_mode?(parsed),
          supported_params: ["q", "season", "ep"]
        },
        movie_search: %{
          available: has_movie_search_mode?(parsed),
          supported_params: ["q", "imdbid", "tmdbid"]
        }
      },
      categories: categories
    }
  end

  defp extract_categories(%{categorymappings: mappings}) when is_list(mappings) do
    Enum.map(mappings, fn mapping ->
      %{
        id: Map.get(mapping, "id"),
        name: Map.get(mapping, "name") || Map.get(mapping, "desc", "Unknown")
      }
    end)
    |> Enum.filter(fn cat -> cat.id != nil end)
  end

  defp extract_categories(_), do: []

  defp has_tv_search_mode?(%{capabilities: %{modes: modes}}) when is_map(modes) do
    Map.has_key?(modes, "tv-search") || Map.has_key?(modes, "tvsearch")
  end

  defp has_tv_search_mode?(_), do: false

  defp has_movie_search_mode?(%{capabilities: %{modes: modes}}) when is_map(modes) do
    Map.has_key?(modes, "movie-search") || Map.has_key?(modes, "moviesearch")
  end

  defp has_movie_search_mode?(_), do: false

  # Build template context for rendering filter arguments during result parsing
  #
  # The operator's settings travel in search_opts[:config] (definition.config, see
  # build_search_opts/4). The session user_config holds only credentials and
  # cookies, so reading :config from it always produced %{} and dropped every
  # setting from filter arguments.
  defp build_template_context_for_parsing(parsed, search_opts) do
    Mydia.Indexers.Cardigann.TemplateContext.build(parsed, search_opts)
  end
end
