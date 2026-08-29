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

  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.Cardigann.Links
  alias Mydia.Indexers.Cardigann.TemplateContext
  alias Mydia.Indexers.CardigannDefinition
  alias Mydia.Indexers.CardigannDefinition.Parsed
  alias Mydia.Indexers.CardigannParser
  alias Mydia.Indexers.CardigannResultParser
  alias Mydia.Indexers.CardigannSearchEngine
  alias Mydia.Repo

  require Logger

  @type test_result :: %{
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
  """
  @type probe_outcome ::
          {:ok, non_neg_integer(), String.t()}
          | {:cloudflare, String.t()}
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
  Runs health checks for all enabled Cardigann indexers.

  This function is designed to be called periodically by a background job
  to monitor the health of all enabled indexers.

  ## Returns

  - `{:ok, results}` - Map of definition_id => test_result
  """
  @spec check_all_enabled() :: {:ok, map()}
  def check_all_enabled do
    enabled_definitions =
      CardigannDefinition
      |> Repo.all()
      |> Enum.filter(& &1.enabled)

    results =
      enabled_definitions
      |> Task.async_stream(
        fn definition ->
          {definition.id, execute_health_check(definition)}
        end,
        timeout: :infinity,
        max_concurrency: 5
      )
      |> Enum.reduce(%{}, fn
        {:ok, {id, {:ok, result}}}, acc -> Map.put(acc, id, result)
        {:ok, {id, {:error, reason}}}, acc -> Map.put(acc, id, %{error: reason})
        _, acc -> acc
      end)

    {:ok, results}
  end

  @doc """
  Probes each base URL candidate in order and returns the first that responds.

  The returned map is suitable for storing in `CardigannDefinition.link_status`
  and records every candidate tried, not only the winner, so the admin UI can
  show why a mirror was skipped.
  """
  @spec probe_candidates(Parsed.t(), map()) ::
          {:ok, String.t(), map()} | {:error, map()}
  def probe_candidates(%Parsed{} = parsed, user_config) do
    parsed
    |> Links.candidates()
    |> Enum.reduce_while({:error, %{}}, fn candidate, {:error, status} ->
      case test_homepage(candidate, user_config) do
        {:ok, http_status} ->
          {:halt, {:ok, candidate, Map.put(status, candidate, ok_entry(http_status))}}

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
         :ok <- CardigannSearchEngine.validate_response(response),
         {:ok, results} <- parse_probe_results(parsed, response, winner, opts) do
      {:ok, length(results), winner}
    else
      {:error, %Error{message: message}} -> classify_probe_error(message)
      {:error, reason} when is_binary(reason) -> classify_probe_error(reason)
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp normalize_search_result({:ok, response}), do: {:ok, response}
  defp normalize_search_result({:ok, response, _flaresolverr_cookies}), do: {:ok, response}
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

  defp classify_probe_error(message) when is_binary(message) do
    if String.contains?(String.downcase(message), "cloudflare") do
      {:cloudflare, message}
    else
      {:error, message}
    end
  end

  defp parse_probe_results(parsed, response, base_url, opts) do
    with {:ok, search_path} <- CardigannSearchEngine.select_search_path(parsed, opts) do
      CardigannResultParser.parse_results(parsed, response, parsed.name,
        template_context: TemplateContext.build(parsed, opts),
        base_url: base_url,
        search_path: search_path
      )
    end
  end

  defp probe_query(%Parsed{capabilities: capabilities}) do
    modes = Map.get(capabilities || %{}, :modes, %{})

    cond do
      Map.has_key?(modes, "movie-search") -> @movie_probe_query
      Map.has_key?(modes, "tv-search") -> @tv_probe_query
      true -> @generic_probe_query
    end
  end

  # Private Functions

  defp perform_test_search(definition, parsed_definition) do
    start_time = System.monotonic_time(:millisecond)
    user_config = definition.config || %{}

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

    case outcome do
      {:ok, 0, served_by} ->
        store_link_state(definition, served_by, link_status)

        %{
          success: true,
          status: "degraded",
          message: "Search reached #{served_by} but parsed no rows",
          response_time_ms: elapsed,
          error: nil
        }

      {:ok, count, served_by} ->
        store_link_state(definition, served_by, link_status)

        %{
          success: true,
          status: determine_health_status(definition, true, elapsed),
          message: "Search returned #{count} result(s) via #{served_by}",
          response_time_ms: elapsed,
          error: nil
        }

      {:cloudflare, message} ->
        store_link_state(definition, active_link, link_status)

        %{
          success: true,
          status: "degraded",
          message:
            "Cloudflare challenge on #{active_link}. Enable FlareSolverr for this indexer.",
          response_time_ms: elapsed,
          error: message
        }

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
    req_opts = [
      receive_timeout: 30_000,
      redirect: true,
      retry: false
    ]

    # Add cookies if present in user config
    req_opts =
      case Map.get(user_config, "cookie") do
        nil ->
          req_opts

        cookie when is_binary(cookie) and cookie != "" ->
          Keyword.put(req_opts, :headers, [{"Cookie", cookie}])

        _ ->
          req_opts
      end

    case Req.get(base_url, req_opts) do
      {:ok, %Req.Response{status: status}} when status in 200..399 ->
        {:ok, status}

      {:ok, %Req.Response{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, "Request timeout"}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, "Connection failed: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end

  defp determine_health_status(definition, success, response_time) do
    cond do
      success && response_time < 5_000 ->
        "healthy"

      success && response_time < 15_000 ->
        "degraded"

      success ->
        "degraded"

      definition.consecutive_failures >= 3 ->
        "unhealthy"

      true ->
        "degraded"
    end
  end

  defp update_health_status(definition, result) do
    now = DateTime.utc_now()

    attrs =
      if result.success do
        %{
          health_status: result.status,
          last_health_check_at: now,
          last_successful_query_at: now,
          consecutive_failures: 0
        }
      else
        %{
          health_status: result.status,
          last_health_check_at: now,
          consecutive_failures: (definition.consecutive_failures || 0) + 1
        }
      end

    definition
    |> CardigannDefinition.health_check_changeset(attrs)
    |> Repo.update()
  end

  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error)

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
      "error" => format_error(error),
      "checked_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end
end
