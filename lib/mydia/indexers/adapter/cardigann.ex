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
  alias Mydia.Indexers.{CardigannDefinition, CardigannAuth, CardigannFeatureFlags}
  alias Mydia.Indexers.CardigannHealthCheck
  alias Mydia.Indexers.CardigannSearchSession
  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Repo

  import Ecto.Query

  require Logger

  @impl true
  def test_connection(config) do
    if CardigannFeatureFlags.enabled?() do
      with {:ok, definition} <- fetch_definition(config),
           {:ok, parsed} <- parse_definition(definition),
           :ok <- test_indexer_reachable(parsed, definition, config) do
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
           {:ok, user_config} <- get_or_create_session(parsed, definition, config),
           flaresolverr_opts <- build_flaresolverr_opts(definition),
           {:ok, response, flaresolverr_result} <-
             execute_search_with_flaresolverr(
               parsed,
               search_opts,
               user_config,
               flaresolverr_opts,
               definition
             ) do
        # Build template context for filter rendering
        template_context = build_template_context_for_parsing(parsed, user_config, search_opts)

        # Get base URL for resolving relative URLs
        base_url =
          definition.active_link || List.first(Mydia.Indexers.Cardigann.Links.candidates(parsed)) ||
            ""

        # Parse results with template context and base URL
        with {:ok, search_path} <- CardigannSearchEngine.select_search_path(parsed, search_opts),
             {:ok, results} <-
               CardigannResultParser.parse_results(parsed, response, config.name,
                 template_context: template_context,
                 base_url: base_url,
                 search_path: search_path
               ) do
          # Handle FlareSolverr result (store cookies, update flags)
          handle_flaresolverr_result(definition, flaresolverr_result)

          # Apply filters from opts if present
          filtered_results = apply_search_filters(results, opts)
          {:ok, filtered_results}
        end
      else
        {:error, %Error{} = error} ->
          {:error, error}

        {:error, reason} ->
          Logger.error("Cardigann search failed: #{inspect(reason)}")
          {:error, Error.search_failed("Search failed: #{inspect(reason)}")}
      end
    else
      Logger.debug("Cardigann search skipped - feature disabled")
      {:ok, []}
    end
  end

  # Execute search and normalize the result to always include flaresolverr_result
  defp execute_search_with_flaresolverr(
         parsed,
         search_opts,
         user_config,
         flaresolverr_opts,
         definition
       ) do
    # Merge FlareSolverr cookies into user_config if available
    user_config_with_fs_cookies = maybe_add_flaresolverr_cookies(user_config, definition)

    case CardigannSearchEngine.execute_search(
           parsed,
           search_opts,
           user_config_with_fs_cookies,
           flaresolverr_opts
         ) do
      {:ok, response, cookies} ->
        {:ok, response, {:flaresolverr_cookies, cookies}}

      {:ok, response} ->
        {:ok, response, :no_flaresolverr}

      {:error, _} = error ->
        error
    end
  end

  # Add FlareSolverr cookies from stored session if available
  defp maybe_add_flaresolverr_cookies(user_config, definition) do
    case get_flaresolverr_session(definition.id) do
      {:ok, session} ->
        # Merge cookies with existing user_config cookies
        existing_cookies = Map.get(user_config, :cookies, [])

        # session.cookies should be a list of cookie maps
        # Handle different formats defensively
        fs_cookies =
          session.cookies
          |> normalize_cookies()
          |> Enum.flat_map(fn
            cookie when is_map(cookie) ->
              name = cookie["name"] || Map.get(cookie, :name)
              value = cookie["value"] || Map.get(cookie, :value)

              if name && value do
                ["#{name}=#{value}"]
              else
                []
              end

            _ ->
              []
          end)

        Map.put(user_config, :cookies, existing_cookies ++ fs_cookies)

      {:error, _} ->
        user_config
    end
  end

  # Normalize cookies from various storage formats to a list of maps
  # Handles: list of maps, map with numeric keys, map with "cookies" key, etc.
  defp normalize_cookies(cookies) when is_list(cookies), do: cookies

  defp normalize_cookies(%{"cookies" => cookies}) when is_list(cookies), do: cookies

  defp normalize_cookies(cookies) when is_map(cookies) do
    # If map values are cookie maps (have "name" key), extract them
    values = Map.values(cookies)

    case values do
      [first | _] when is_map(first) and is_map_key(first, "name") ->
        values

      [first | _] when is_list(first) ->
        # Nested list - flatten one level
        List.flatten(values)

      _ ->
        []
    end
  end

  defp normalize_cookies(_), do: []

  # Build FlareSolverr options from definition
  defp build_flaresolverr_opts(%CardigannDefinition{} = definition) do
    %{
      enabled: CardigannDefinition.use_flaresolverr?(definition),
      definition_id: definition.id
    }
  end

  # Handle FlareSolverr result - store cookies and update flags
  defp handle_flaresolverr_result(definition, {:flaresolverr_cookies, cookies}) do
    # Check if FlareSolverr was auto-detected as required
    flaresolverr_required =
      Enum.find(cookies, fn
        {:flaresolverr_required, true} -> true
        _ -> false
      end)

    # Extract actual cookies (filter out metadata)
    actual_cookies =
      Enum.reject(cookies, fn
        {:flaresolverr_required, _} -> true
        _ -> false
      end)

    # Update definition if FlareSolverr was auto-detected
    if flaresolverr_required do
      mark_flaresolverr_required(definition)
    end

    # Store cookies for future requests
    if actual_cookies != [] do
      store_flaresolverr_cookies(definition, actual_cookies)
    end

    :ok
  end

  defp handle_flaresolverr_result(_definition, :no_flaresolverr), do: :ok

  # Mark an indexer as requiring FlareSolverr
  defp mark_flaresolverr_required(%CardigannDefinition{flaresolverr_required: true}), do: :ok

  defp mark_flaresolverr_required(%CardigannDefinition{} = definition) do
    Logger.info("Auto-detected FlareSolverr requirement for indexer: #{definition.indexer_id}")

    definition
    |> CardigannDefinition.flaresolverr_changeset(%{
      flaresolverr_required: true,
      flaresolverr_enabled: true
    })
    |> Repo.update()
    |> case do
      {:ok, _} ->
        Logger.debug("Updated indexer #{definition.indexer_id} FlareSolverr settings")

      {:error, changeset} ->
        Logger.error("Failed to update FlareSolverr settings: #{inspect(changeset.errors)}")
    end
  end

  # Store FlareSolverr cookies in the database
  defp store_flaresolverr_cookies(%CardigannDefinition{} = definition, cookies) do
    # Convert cookies to JSON-serializable format
    cookie_data =
      Enum.map(cookies, fn cookie ->
        %{
          "name" => cookie.name,
          "value" => cookie.value,
          "domain" => cookie.domain,
          "path" => cookie.path || "/",
          "expires" => cookie.expires,
          "secure" => cookie.secure || false,
          "httpOnly" => cookie.http_only || false
        }
      end)

    # Calculate expiration from cookies (use earliest expiration, default 1 hour)
    expires_at = calculate_cookie_expiration(cookies)

    # Upsert the session
    case get_flaresolverr_session(definition.id) do
      {:ok, session} ->
        # Update existing session
        session
        |> CardigannSearchSession.changeset(%{
          cookies: cookie_data,
          expires_at: expires_at
        })
        |> Repo.update()

      {:error, :not_found} ->
        # Create new session
        %CardigannSearchSession{}
        |> CardigannSearchSession.changeset(%{
          cardigann_definition_id: definition.id,
          cookies: cookie_data,
          expires_at: expires_at
        })
        |> Repo.insert()
    end
    |> case do
      {:ok, _} ->
        Logger.debug(
          "Stored #{length(cookies)} FlareSolverr cookies for #{definition.indexer_id}"
        )

      {:error, changeset} ->
        Logger.error("Failed to store FlareSolverr cookies: #{inspect(changeset.errors)}")
    end
  end

  # Calculate expiration time from cookies
  defp calculate_cookie_expiration(cookies) do
    # Find the earliest expiration time from cookies
    min_expiration =
      cookies
      |> Enum.map(fn cookie -> cookie.expires end)
      |> Enum.reject(&is_nil/1)
      |> Enum.min(fn -> nil end)

    case min_expiration do
      nil ->
        # Default to 1 hour if no expiration set
        DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

      timestamp when is_number(timestamp) ->
        # Convert Unix timestamp to DateTime
        DateTime.from_unix!(trunc(timestamp)) |> DateTime.truncate(:second)
    end
  end

  # Get stored FlareSolverr session
  defp get_flaresolverr_session(definition_id) do
    query =
      from s in CardigannSearchSession,
        where: s.cardigann_definition_id == ^definition_id,
        order_by: [desc: s.updated_at],
        limit: 1

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      session ->
        # Check if session is expired
        if CardigannSearchSession.expired?(session) do
          # Delete the stale row and treat it as absent. Callers only need to
          # distinguish "usable session" from "no usable session", so expired
          # collapses into :not_found rather than exposing a third return value.
          Repo.delete(session)
          {:error, :not_found}
        else
          {:ok, session}
        end
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

  defp fetch_definition(%{indexer_id: indexer_id}) do
    case Repo.get_by(CardigannDefinition, indexer_id: indexer_id) do
      nil ->
        {:error, Error.invalid_config("Cardigann definition not found: #{indexer_id}")}

      definition ->
        {:ok, definition}
    end
  end

  defp fetch_definition(_config) do
    {:error, Error.invalid_config("Missing indexer_id in config")}
  end

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
  # Also takes the caller-supplied adapter config (not just the
  # CardigannDefinition) so the probe can build the same authenticated session
  # get_or_create_session/3 builds for a real search. Without it, a private
  # indexer with a stored session (or one whose login the caller's credentials
  # can satisfy) probed unauthenticated and reported a false connection
  # failure while its real, authenticated searches kept succeeding - the exact
  # false red this task exists to eliminate, mirror image of the false green
  # above.
  #
  # The template-context :config still comes from definition.config alone,
  # never from the adapter config's :user_settings or a nested :config key:
  # build_search_opts/4 (the real search path) does the same, so sourcing it
  # any other way here would let the probe render {{ .Config.* }} differently
  # than a real search does, either dropping settings that do work or
  # reporting settings that don't. build_probe_user_config/3 layers the
  # session's cookies/api_key on top of definition.config instead of
  # replacing it, so both stay true at once.
  defp test_indexer_reachable(parsed, %CardigannDefinition{} = definition, config) do
    with {:ok, user_config} <- build_probe_user_config(parsed, definition, config) do
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

  # Builds the same authenticated session get_or_create_session/3 builds for a
  # real search (a stored session's cookies, or a fresh login when the
  # definition requires one), then layers it onto definition.config. A
  # genuine login failure (credentials configured but rejected) surfaces as a
  # connection failure here, same as it would surface as a search failure for
  # a real search; an indexer with no credentials configured authenticates as
  # :none and is not penalized for it, matching get_or_create_session/3's own
  # success case for public indexers.
  defp build_probe_user_config(parsed, %CardigannDefinition{} = definition, config) do
    with {:ok, session_user_config} <- get_or_create_session(parsed, definition, config) do
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
      on_promote: fn winning_url ->
        definition
        |> Ecto.Changeset.change(%{active_link: winning_url})
        |> Mydia.Repo.update()
      end
    ]

    {:ok, search_opts}
  end

  defp get_or_create_session(parsed, definition, config) do
    user_settings = Map.get(config, :user_settings, %{})

    # Build user config from settings
    credentials = %{
      username: Map.get(user_settings, :username),
      password: Map.get(user_settings, :password),
      api_key: Map.get(user_settings, :api_key),
      cookies: Map.get(user_settings, :cookies, [])
    }

    # Remove nil values
    credentials = Map.reject(credentials, fn {_k, v} -> is_nil(v) end)

    # Try to get stored session first
    case CardigannAuth.get_stored_session(definition.id) do
      {:ok, session} ->
        # Validate session hasn't expired
        if CardigannAuth.validate_session(session, parsed) do
          {:ok, convert_session_to_user_config(session)}
        else
          # Session expired, re-authenticate
          authenticate_and_convert(parsed, credentials, definition.id)
        end

      {:error, :not_found} ->
        # No stored session, authenticate if needed
        authenticate_and_convert(parsed, credentials, definition.id)

      {:error, :expired} ->
        # Session expired, re-authenticate
        authenticate_and_convert(parsed, credentials, definition.id)
    end
  end

  defp authenticate_and_convert(parsed, credentials, definition_id) do
    case CardigannAuth.authenticate(parsed, credentials, definition_id) do
      {:ok, session} ->
        {:ok, convert_session_to_user_config(session)}

      {:error, error} ->
        # If authentication is required but failed, return error
        # Otherwise return empty config for public indexers
        if parsed.login != nil and credentials != %{} do
          {:error, error}
        else
          {:ok, %{}}
        end
    end
  end

  defp convert_session_to_user_config(session) do
    case session.method do
      :api_key ->
        %{api_key: session.api_key}

      :cookie ->
        %{cookies: session.cookies}

      :form ->
        %{cookies: session.cookies}

      :none ->
        %{}
    end
  end

  defp apply_search_filters(results, opts) do
    results
    |> filter_by_min_seeders(Keyword.get(opts, :min_seeders, 0))
    |> filter_by_min_size(Keyword.get(opts, :min_size))
    |> filter_by_max_size(Keyword.get(opts, :max_size))
    |> limit_results(Keyword.get(opts, :limit))
  end

  defp filter_by_min_seeders(results, min_seeders) when min_seeders > 0 do
    # NZB results have nil seeders; the min-seeders setting is torrent-only.
    Enum.filter(results, fn result -> is_nil(result.seeders) or result.seeders >= min_seeders end)
  end

  defp filter_by_min_seeders(results, _), do: results

  defp filter_by_min_size(results, nil), do: results

  defp filter_by_min_size(results, min_size) do
    Enum.filter(results, fn result -> result.size >= min_size end)
  end

  defp filter_by_max_size(results, nil), do: results

  defp filter_by_max_size(results, max_size) do
    Enum.filter(results, fn result -> result.size <= max_size end)
  end

  defp limit_results(results, nil), do: results
  defp limit_results(results, limit), do: Enum.take(results, limit)

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
  defp build_template_context_for_parsing(parsed, user_config, search_opts) do
    config_map =
      case user_config do
        %{config: config} when is_map(config) -> config
        %{"config" => config} when is_map(config) -> config
        _ -> %{}
      end

    search_opts
    |> Keyword.put(:config, config_map)
    |> then(&Mydia.Indexers.Cardigann.TemplateContext.build(parsed, &1))
  end
end
