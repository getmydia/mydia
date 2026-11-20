defmodule Mydia.Indexers.CardigannHealthCheck do
  @moduledoc """
  Health check functionality for Cardigann indexers.

  Provides manual test connection and automated health monitoring features
  for Cardigann-based indexers.

  ## Features

  - Manual test connection from UI
  - Automated periodic health checks
  - Health status tracking (healthy/degraded/unhealthy/unknown)
  - Response time measurement
  - Consecutive failure tracking
  """

  import Mydia.Indexers.CardigannHealthCheck.Status,
    only: [
      determine_health_status: 3,
      needs_login_result: 0,
      note_success: 2,
      rate_limited_result: 3
    ]

  alias Mydia.Indexers
  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.Adapter.Registry
  alias Mydia.Indexers.Cardigann.BlockPage
  alias Mydia.Indexers.Cardigann.EngineSwitcher
  alias Mydia.Indexers.Cardigann.CredentialScope
  alias Mydia.Indexers.Cardigann.Links
  alias Mydia.Indexers.Cardigann.ResponseCheck
  alias Mydia.Indexers.Cardigann.SessionManager
  alias Mydia.Indexers.Cardigann.TemplateContext
  alias Mydia.Indexers.CardigannDefinition
  alias Mydia.Indexers.CardigannDefinition.Parsed
  alias Mydia.Indexers.CardigannParser
  alias Mydia.Indexers.CardigannResultParser
  alias Mydia.Indexers.CardigannHealthCheck.{Status, Sweep}
  alias Mydia.Indexers.CardigannSearchEngine
  alias Mydia.Indexers.SearchStats
  alias Mydia.Indexers.SearchStats.Network
  alias Mydia.Repo

  @type test_result :: %{
          optional(:network_ms) => non_neg_integer() | nil,
          optional(:rate_limited) => true,
          success: boolean(),
          status: String.t(),
          message: String.t(),
          response_time_ms: non_neg_integer() | nil,
          error: String.t() | nil
        }

  # A single fixed probe query reads as "no rows" on every tracker that does not
  # carry that kind of content, which trains an operator to ignore the degraded
  # state. Ask the indexer something it says it can answer.
  @movie_probe_query "The Matrix"
  @tv_probe_query "Breaking Bad"
  @generic_probe_query "ubuntu"

  @typedoc """
  Outcome of a real search against one base URL.

  `{:ok, count, served_by}` where count is 0 means the site answered and
  parsed cleanly but matched nothing, which is degraded rather than healthy
  or failed. `served_by` is the URL that actually produced the response:
  `execute_search/4` fails over past `base_url` to later candidates on a
  retryable failure (a dead or wrong mirror answering 404, say), so the
  candidate that answered is not always the one the probe was asked to try.

  `{:rate_limited, error}` is the tracker answering HTTP 429; the error's
  `details.retry_after` carries its `Retry-After` in milliseconds, or nil.
  """
  @type probe_outcome ::
          {:ok, non_neg_integer(), String.t()}
          | {:cloudflare, String.t()}
          | {:rate_limited, Error.t()}
          | {:error, String.t()}

  @doc """
  Tests connection to an indexer by executing a simple test search.

  Executes a lightweight test query to verify the indexer is reachable,
  authentication works, and results can be parsed.

  ## Parameters

  - `definition_id` - ID of the Cardigann definition to test
  - `opts` - Optional test options

  ## Returns

  - `{:ok, test_result}` - Test completed (may indicate success or failure)
  - `{:error, reason}` - Test could not be executed

  ## Examples

      iex> test_connection(definition_id)
      {:ok, %{success: true, status: "healthy", message: "Connection successful", response_time_ms: 245}}

      iex> test_connection(definition_id)
      {:ok, %{success: false, status: "unhealthy", message: "Connection failed", error: "Timeout"}}
  """
  @spec test_connection(String.t(), keyword()) :: {:ok, test_result()} | {:error, String.t()}
  def test_connection(definition_id, opts \\ []) do
    case Repo.get(CardigannDefinition, definition_id) do
      nil ->
        {:error, "Indexer definition not found"}

      definition ->
        execute_health_check(definition, opts)
    end
  end

  @doc """
  Executes health check for a given definition and updates health status.

  Performs a test search, measures response time, and updates the definition's
  health status in the database.

  ## Parameters

  - `definition` - CardigannDefinition struct
  - `opts` - Optional health check options

  ## Returns

  - `{:ok, test_result}` - Health check completed and status updated
  - `{:error, reason}` - Health check failed
  """
  @spec execute_health_check(CardigannDefinition.t(), keyword()) ::
          {:ok, test_result()} | {:error, String.t()}
  def execute_health_check(%CardigannDefinition{} = definition, _opts \\ []) do
    # The probe (homepage GET, search, any login) runs in this process, so
    # Network counts its requests.
    Network.reset()
    result = run_health_check(definition)
    record_health(definition, result, Network.take_requests())
    result
  end

  defp run_health_check(definition) do
    # Parse the definition
    case CardigannParser.parse_definition(definition.definition) do
      {:ok, parsed_definition} ->
        perform_test_search(definition, parsed_definition)

      {:error, reason} ->
        result = %{
          success: false,
          status: "unhealthy",
          message: "Failed to parse definition",
          response_time_ms: nil,
          error: inspect(reason)
        }

        update_health_status(definition, result)
        {:ok, result}
    end
  end

  @doc """
  Runs health checks for all enabled Cardigann indexers, skipping cooling
  ones and trusting a recent real search. See `Sweep`.
  """
  @spec check_all_enabled() :: {:ok, map()}
  defdelegate check_all_enabled, to: Sweep

  @doc false
  defdelegate update_health_status(definition, result), to: Status

  @doc """
  Probes each base URL candidate in order and returns the first that responds.

  The returned map is suitable for storing in `CardigannDefinition.link_status`
  and records every candidate tried, not only the winner, so the admin UI can
  show why a mirror was skipped.

  A homepage answering HTTP 429 stops the walk with
  `{:rate_limited, retry_after_ms, status}`: the tracker is throttling Mydia,
  and asking its other mirrors would only add to it.
  """
  @spec probe_candidates(Parsed.t(), map()) ::
          {:ok, String.t(), map()}
          | {:rate_limited, non_neg_integer() | nil, map()}
          | {:error, map()}
  def probe_candidates(%Parsed{} = parsed, user_config) do
    parsed
    |> Links.candidates()
    |> Enum.reduce_while({:error, %{}}, fn candidate, {:error, status} ->
      case test_homepage(candidate, user_config) do
        {:ok, http_status} ->
          {:halt, {:ok, candidate, Map.put(status, candidate, ok_entry(http_status))}}

        {:rate_limited, retry_after} ->
          {:halt,
           {:rate_limited, retry_after, Map.put(status, candidate, error_entry("HTTP 429"))}}

        {:error, error} ->
          {:cont, {:error, Map.put(status, candidate, error_entry(error))}}
      end
    end)
  end

  @doc """
  Runs a real search against `base_url` and reports what came back.

  The homepage probe in `probe_candidates/2` only proves the site answers on
  `/`. Every defect in the 1.4 indexer bug report lived in the search leg: an
  unescaped query in the URL path, an absolute path concatenated onto the base
  URL, a redirect nobody followed, a 404 that ended the search instead of
  advancing to the next mirror. A Test that stopped at the homepage reported
  "successful" for all of them, which is how five broken indexers shipped with
  five green checkmarks.
  """
  @spec probe_search(Parsed.t(), map(), String.t()) :: probe_outcome()
  def probe_search(%Parsed{} = parsed, user_config, base_url) do
    opts = [
      query: probe_query(parsed),
      categories: [],
      # user_config is already the flat settings map (definition.config, see
      # perform_test_search/2), not a wrapper holding a nested :config key.
      # Map.get(user_config, :config, %{}) used to always evaluate to %{},
      # silently dropping every user-supplied setting (API keys, mirror
      # overrides, auth tokens) from the probe's template context while the
      # real search rendered them correctly. That made the probe capable of
      # reporting a false failure/degraded for a correctly configured
      # indexer, the exact inverse of the false green this task removes.
      config: user_config,
      settings: parsed.settings,
      base_url: base_url,
      on_promote: &report_promotion/1
    ]

    with {:ok, response} <-
           parsed
           |> CardigannSearchEngine.execute_search(opts, user_config, %{})
           |> normalize_search_result(),
         # Read the promotion signal as soon as execute_search/4 returns, before
         # resolving relative result URLs against the (possibly stale) base_url
         # argument below.
         winner = served_by(base_url),
         :ok <- ResponseCheck.validate_response(response),
         {:ok, results, stats} <- parse_probe_results(parsed, response, winner, opts),
         :ok <- ensure_usable(results, stats) do
      {:ok, length(results), winner}
    else
      {:error, %Error{type: :rate_limited} = error} -> {:rate_limited, error}
      {:error, %Error{message: message}} -> classify_probe_error(message)
    end
  end

  defp normalize_search_result({:ok, response}), do: {:ok, response}
  defp normalize_search_result({:ok, response, _flaresolverr_markers}), do: {:ok, response}
  defp normalize_search_result(other), do: other

  # execute_search/4 calls opts[:on_promote] with the winning candidate URL
  # only when it had to fail over past the first one tried (build_search_opts/4
  # uses the same hook to persist active_link after a real search). try_candidates/7
  # runs synchronously in this process, so a self-message survives the call and
  # lets probe_search report which mirror actually served the result instead of
  # the one it was asked to try. At most one promotion happens per probe_search
  # call, so there is nothing to drain beforehand.
  defp report_promotion(winning_url), do: send(self(), {:cardigann_probe_promoted, winning_url})

  defp served_by(default_url) do
    receive do
      {:cardigann_probe_promoted, winning_url} -> winning_url
    after
      0 -> default_url
    end
  end

  # The engine prefixes every FlareSolverr failure with "FlareSolverr:" (see
  # Cardigann.FlareSolverrFlow), so a crashed tab or a rejected cookie reads as the
  # challenge problem it is rather than as a generic search failure.
  @doc false
  def classify_probe_error(message) when is_binary(message) do
    lower = String.downcase(message)

    if String.contains?(lower, "cloudflare") or String.starts_with?(message, "FlareSolverr:") do
      {:cloudflare, message}
    else
      {:error, message}
    end
  end

  defp parse_probe_results(parsed, response, base_url, opts) do
    with {:ok, search_path} <- CardigannSearchEngine.select_search_path(parsed, opts) do
      CardigannResultParser.parse_results_with_stats(parsed, response, parsed.name,
        template_context: TemplateContext.build(parsed, opts),
        base_url: base_url,
        search_path: search_path
      )
    end
  end

  # Rows the selector matched but that were all discarded for a missing title or
  # download are a broken definition, not an empty search. Report them as an
  # error so the definition is marked degraded instead of healthy with zero.
  # Only when the drops alone explain the empty result: rows removed on purpose
  # by `andmatch` mean the search simply had nothing relevant.
  defp ensure_usable([], %{
         dropped: dropped,
         filtered: 0,
         matched: matched,
         first_missing: missing
       })
       when dropped > 0 do
    {:error,
     Error.search_failed("#{matched} rows matched, none usable (missing #{missing || "unknown"})")}
  end

  defp ensure_usable(_results, _stats), do: :ok

  @doc """
  True when `candidate` may become the definition's sticky `active_link`.

  `Links.candidates/1` offers `legacylinks` as failover targets, and a legacy
  domain that answers would otherwise become sticky, silently readmitting a host
  the credential scope excludes. The rule is conditional on credentials because
  42 of the 81 public v11 definitions ship legacylinks and depend on promoting
  them, while having no session to protect.
  """
  @spec promotable?(Parsed.t(), map(), String.t() | nil) :: boolean()
  def promotable?(%Parsed{} = parsed, user_config, candidate) when is_binary(candidate) do
    not CredentialScope.credentialed?(user_config) or
      CredentialScope.allows?(CredentialScope.trusted_origins(parsed, user_config), candidate)
  end

  def promotable?(_parsed, _user_config, _candidate), do: false

  @doc """
  The query a probe search sends: a movie title for movie-search definitions, a
  series for tv-search, otherwise a generic term.
  """
  @spec probe_query(Parsed.t()) :: String.t()
  def probe_query(%Parsed{capabilities: capabilities}) do
    # Map.get/3's default only applies when the key is ABSENT. A parsed
    # definition can have `modes: nil` (key present, value nil), in which case
    # Map.get(capabilities, :modes, %{}) returns nil, not %{}, and the
    # Map.has_key?(modes, ...) calls below raise BadMapError before any of
    # the surrounding error handling runs.
    modes = Map.get(capabilities || %{}, :modes) || %{}

    cond do
      Map.has_key?(modes, "movie-search") -> @movie_probe_query
      Map.has_key?(modes, "tv-search") -> @tv_probe_query
      true -> @generic_probe_query
    end
  end

  # Private Functions

  # A needs_login check is not a probe of the tracker, so it is not recorded.
  defp record_health(_definition, {:ok, %{status: "needs_login"}}, _requests), do: :ok

  defp record_health(definition, {:ok, result}, requests) do
    SearchStats.Telemetry.emit(Indexers.cardigann_config(definition),
      kind: :health,
      outcome: if(result.status == "healthy", do: :ok, else: result.status),
      duration_ms: result.response_time_ms || 0,
      network_ms: result[:network_ms],
      http_requests: requests,
      error_message: result[:error]
    )
  end

  defp perform_test_search(definition, parsed_definition) do
    if EngineSwitcher.active() == :prowlarr,
      do: prowlarr_probe(definition, parsed_definition),
      else: builtin_probe(definition, parsed_definition)
  end

  # The Prowlarr engine owns its session, mirror failover and FlareSolverr, so
  # the probe is one search through whatever adapter serves :cardigann now,
  # with the same probe query the built-in path uses. Mirror state
  # (active_link, link_status) is left as the adapter leaves it.
  defp prowlarr_probe(definition, parsed) do
    start_time = System.monotonic_time(:millisecond)

    Network.reset()

    outcome =
      with {:ok, adapter} <- Registry.get_adapter(:cardigann) do
        adapter.search(Indexers.cardigann_config(definition), probe_query(parsed), [])
      end

    network_ms = Network.take_ms()
    elapsed = System.monotonic_time(:millisecond) - start_time

    note_success(definition, outcome)

    case outcome do
      {:error, %Error{type: :login_required}} ->
        {:ok, needs_login_result()}

      outcome ->
        result = prowlarr_result(definition, outcome, elapsed)
        update_health_status(definition, result)
        {:ok, Map.put(result, :network_ms, network_ms)}
    end
  end

  defp prowlarr_result(_definition, {:ok, []}, elapsed) do
    %{
      success: true,
      status: "degraded",
      message: "Search parsed no rows",
      response_time_ms: elapsed,
      error: nil
    }
  end

  defp prowlarr_result(definition, {:ok, results}, elapsed) do
    %{
      success: true,
      status: determine_health_status(definition, true, elapsed),
      message: "Search returned #{length(results)} result(s)",
      response_time_ms: elapsed,
      error: nil
    }
  end

  defp prowlarr_result(definition, {:error, %Error{type: :rate_limited} = error}, elapsed),
    do: rate_limited_result(definition, error, elapsed)

  defp prowlarr_result(definition, {:error, %Error{message: message}}, elapsed) do
    case classify_probe_error(message) do
      {:cloudflare, message} ->
        %{
          success: true,
          status: "degraded",
          message: message,
          response_time_ms: elapsed,
          error: message
        }

      {:error, message} ->
        %{
          success: false,
          status: determine_health_status(definition, false, elapsed),
          message: "Search failed",
          response_time_ms: elapsed,
          error: message
        }
    end
  end

  defp builtin_probe(definition, parsed_definition) do
    start_time = System.monotonic_time(:millisecond)

    case SessionManager.user_config(parsed_definition, definition) do
      {:ok, session_config} ->
        user_config = Map.merge(definition.config || %{}, session_config)
        probe_with_session(definition, parsed_definition, user_config, start_time)

      {:error, %Error{type: :login_required}} ->
        {:ok, needs_login_result()}

      {:error, %Error{message: message}} ->
        result = %{
          success: false,
          status: determine_health_status(definition, false, 0),
          message: "Login failed",
          response_time_ms: nil,
          error: message
        }

        update_health_status(definition, result)
        {:ok, result}
    end
  end

  defp probe_with_session(definition, parsed_definition, user_config, start_time) do
    result =
      case probe_candidates(parsed_definition, user_config) do
        {:ok, active_link, link_status} ->
          search_leg(
            definition,
            parsed_definition,
            user_config,
            active_link,
            link_status,
            start_time
          )

        {:rate_limited, retry_after, link_status} ->
          store_link_state(definition, nil, link_status)
          error = Error.rate_limited("Homepage answered HTTP 429", %{retry_after: retry_after})
          rate_limited_result(definition, error, System.monotonic_time(:millisecond) - start_time)

        {:error, link_status} ->
          store_link_state(definition, nil, link_status)
          elapsed = System.monotonic_time(:millisecond) - start_time

          # Use the same escalation determine_health_status/3 applies to a
          # search failure below: a transient network blip should read as
          # degraded, same as a persistent search defect, and only climb to
          # unhealthy after consecutive_failures/3 crosses the threshold.
          # Hardcoding "unhealthy" here made one unreachable probe report
          # worse than a search that has been broken for weeks.
          %{
            success: false,
            status: determine_health_status(definition, false, elapsed),
            message: "No reachable base URL",
            response_time_ms: elapsed,
            error: "All #{map_size(link_status)} candidate links failed"
          }
      end

    update_health_status(definition, result)
    {:ok, result}
  end

  defp search_leg(definition, parsed, user_config, active_link, link_status, start_time) do
    outcome = probe_search(parsed, user_config, active_link)
    elapsed = System.monotonic_time(:millisecond) - start_time

    note_success(definition, outcome)

    case outcome do
      {:ok, 0, served_by} ->
        store_link_state(
          definition,
          promoted_link(definition, parsed, user_config, served_by),
          link_status
        )

        %{
          success: true,
          status: "degraded",
          message:
            "Search reached #{served_by} but parsed no rows" <>
              (anonymous_search_note(parsed, user_config, served_by) || ""),
          response_time_ms: elapsed,
          error: nil
        }

      {:ok, count, served_by} ->
        store_link_state(
          definition,
          promoted_link(definition, parsed, user_config, served_by),
          link_status
        )

        note = anonymous_search_note(parsed, user_config, served_by)

        %{
          success: true,
          status:
            if(note, do: "degraded", else: determine_health_status(definition, true, elapsed)),
          message: "Search returned #{count} result(s) via #{served_by}#{note}",
          response_time_ms: elapsed,
          error: nil
        }

      {:cloudflare, message} ->
        store_link_state(
          definition,
          promoted_link(definition, parsed, user_config, active_link),
          link_status
        )

        %{
          success: true,
          status: "degraded",
          message:
            if(String.starts_with?(message, "FlareSolverr:"),
              do: "#{message} (via #{active_link})",
              else:
                "Cloudflare challenge on #{active_link}. Enable FlareSolverr for this indexer."
            ),
          response_time_ms: elapsed,
          error: message
        }

      {:rate_limited, error} ->
        # The tracker said nothing about this mirror's search beyond "not now",
        # so it is not promoted.
        store_link_state(definition, nil, link_status)
        rate_limited_result(definition, error, elapsed)

      {:error, message} ->
        # The homepage answered but the search did not, so this candidate is not
        # a working base URL and must not be promoted to active_link on the
        # strength of a homepage GET.
        store_link_state(definition, nil, link_status)

        %{
          success: false,
          status: determine_health_status(definition, false, elapsed),
          message: "Search failed via #{active_link}",
          response_time_ms: elapsed,
          error: message
        }
    end
  end

  # An operator whose private tracker suddenly returns nothing deserves to be
  # told why. A search served by a host outside the credential scope went out
  # without its session, so it is degraded rather than healthy no matter how
  # many rows it parsed.
  defp anonymous_search_note(parsed, user_config, served_by) do
    cond do
      not CredentialScope.credentialed?(user_config) ->
        nil

      CredentialScope.allows?(CredentialScope.trusted_origins(parsed, user_config), served_by) ->
        nil

      true ->
        " Searched anonymously: #{served_by} is not one of this definition's own hosts, " <>
          "so its session was withheld."
    end
  end

  # Links.candidates/1 offers legacylinks as failover targets, so a probe can
  # land on one. Persisting it as the sticky active_link would quietly readmit a
  # host the credential scope excludes, for every later request. Falling back to
  # the current active_link leaves the field untouched rather than clearing it.
  defp promoted_link(definition, parsed, user_config, candidate) do
    if promotable?(parsed, user_config, candidate) do
      candidate
    else
      definition.active_link
    end
  end

  defp store_link_state(definition, nil, link_status) do
    definition
    |> Ecto.Changeset.change(%{link_status: link_status})
    |> Repo.update()
  end

  defp store_link_state(definition, active_link, link_status) do
    definition
    |> Ecto.Changeset.change(%{active_link: active_link, link_status: link_status})
    |> Repo.update()
  end

  defp test_homepage(nil, _user_config), do: {:error, "No base URL configured"}

  defp test_homepage(base_url, user_config) do
    response = Req.get(base_url, Network.count_dispatches(homepage_request_opts(user_config)))
    classify_homepage(response, base_url)
  end

  defp homepage_request_opts(user_config) do
    opts = [receive_timeout: 30_000, redirect: true, retry: false]

    # Add cookies if present in user config
    case Map.get(user_config, "cookie") do
      cookie when is_binary(cookie) and cookie != "" ->
        Keyword.put(opts, :headers, [{"Cookie", cookie}])

      _ ->
        opts
    end
  end

  defp classify_homepage({:ok, %Req.Response{status: status, body: body}}, _url)
       when status in 200..399 do
    case BlockPage.fingerprint(body) do
      nil -> {:ok, status}
      title -> {:error, "Blocked page: #{title}"}
    end
  end

  defp classify_homepage({:ok, %Req.Response{status: 429, headers: headers}}, _url),
    do: {:rate_limited, Error.retry_after_ms(headers)}

  defp classify_homepage({:ok, %Req.Response{status: status}}, _url),
    do: {:error, "HTTP #{status}"}

  defp classify_homepage({:error, %Req.TransportError{reason: :timeout}}, _url),
    do: {:error, "Request timeout"}

  defp classify_homepage({:error, reason}, url) do
    proxy_msg = Mydia.Net.Proxy.describe_error(reason, URI.parse(url).host)

    case {proxy_msg, reason} do
      {msg, _} when is_binary(msg) -> {:error, msg}
      {nil, %Req.TransportError{reason: r}} -> {:error, "Connection failed: #{inspect(r)}"}
      {nil, other} -> {:error, "Request failed: #{inspect(other)}"}
    end
  end

  defp ok_entry(http_status) do
    %{
      "ok" => true,
      "status" => http_status,
      "error" => nil,
      "checked_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp error_entry(error) do
    %{
      "ok" => false,
      "status" => nil,
      "error" => error,
      "checked_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end
end
