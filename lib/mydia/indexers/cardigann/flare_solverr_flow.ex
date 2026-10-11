defmodule Mydia.Indexers.Cardigann.FlareSolverrFlow do
  @moduledoc """
  The FlareSolverr leg of a Cardigann search: earning a Cloudflare clearance and
  repeating the request with it.

  `Mydia.Indexers.CardigannSearchEngine` decides when a request is challenged
  and what to do with the result. Everything that happens once FlareSolverr is
  involved lives here: whether to solve before the first direct attempt, the
  solve itself, the repeat that uses the clearance, the rendered-page fallback,
  and the operator-facing text for each way FlareSolverr can fail. The flow
  calls back into the engine's public HTTP helpers, so the request, challenge
  and response checks behave exactly as on a direct request.
  """

  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.CardigannSearchEngine
  alias Mydia.Indexers.FlareSolverr
  alias Mydia.Indexers.FlareSolverr.ClearanceCache
  alias Mydia.Indexers.FlareSolverr.Response, as: FlareSolverrResponse

  require Logger

  # An indexer already known to sit behind Cloudflare skips the doomed direct
  # request, unless a clearance for this host is cached, in which case the
  # direct request is exactly what the clearance is for.
  @doc """
  Whether the first attempt should go to FlareSolverr instead of straight out.
  """
  @spec solve_first?(map(), String.t()) :: boolean()
  def solve_first?(flaresolverr_opts, url) do
    flaresolverr_opts[:enabled] == true and FlareSolverr.enabled?() and
      ClearanceCache.lookup(url) == :none
  end

  # Prowlarr's model (IndexerProxies/FlareSolverr/FlareSolverr.cs): FlareSolverr
  # gets the bare request, never cookies, and is used to earn a clearance, not
  # to fetch the page. The request is then repeated directly with the
  # clearance and that response is parsed, so the definition's own headers
  # (EZTV's layout cookie, a user-agent) apply exactly as on any direct
  # request. Parsing Chrome's rendered DOM instead dropped those headers and
  # returned zero rows for 1337x, EZTV and kickass while Prowlarr returned
  # plenty. The rendered DOM is kept only as a fallback for a site whose
  # clearance does not carry over to a plain HTTP client.
  #
  # No explicit rate limit here: execute_http_request/5 applies the definition's
  # request_delay before the repeat, and the direct attempt that preceded a
  # solve applied it before the challenge, so the site is not paced three times.
  @doc """
  Solves the challenge for `url`, caches the clearance and repeats the request.
  """
  @spec solve_and_repeat(struct(), String.t(), map(), map(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def solve_and_repeat(definition, url, request_params, user_config, config) do
    case solve(url, request_params) do
      {:ok, %FlareSolverrResponse{} = solved} ->
        ClearanceCache.put(
          url,
          FlareSolverrResponse.cookies(solved),
          FlareSolverrResponse.user_agent(solved)
        )

        repeat_after_solve(definition, url, request_params, user_config, config, solved)

      {:error, reason} ->
        {:error, flaresolverr_error(definition.id, reason)}
    end
  end

  defp repeat_after_solve(definition, url, request_params, user_config, config, solved) do
    case CardigannSearchEngine.execute_http_request(
           definition,
           url,
           request_params,
           user_config,
           config
         ) do
      {:ok, response} ->
        accept_repeat(response, definition, url, solved)

      {:error, _} = error ->
        error
    end
  end

  defp accept_repeat(response, definition, url, solved) do
    if CardigannSearchEngine.cloudflare_challenge?(response) do
      Logger.info(
        "Cardigann: #{definition.id} still challenged after FlareSolverr; " <>
          "using the rendered page"
      )

      # The clearance did not carry over, so caching it only makes every
      # later search pay a doomed direct request first.
      ClearanceCache.delete(url)
      validated(rendered_response(solved))
    else
      validated(response)
    end
  end

  defp validated(response) do
    with :ok <- CardigannSearchEngine.validate_response(response), do: {:ok, response}
  end

  defp rendered_response(solved) do
    %{
      status: FlareSolverrResponse.http_status(solved) || 200,
      body: FlareSolverrResponse.body(solved) || "",
      headers: convert_flaresolverr_headers(solved)
    }
  end

  defp solve(url, %{method: :get, query_params: params}),
    do: FlareSolverr.get(append_query_params(url, params))

  defp solve(url, %{method: :post, query_params: params}),
    do: FlareSolverr.post(url, post_data: URI.encode_query(params))

  # Operator-facing text for a FlareSolverr failure. Every message starts with
  # "FlareSolverr:" so the connection test can recognise it, and none of them
  # inspects the raw reason, which used to put FlareSolverr's whole JSON body
  # and Chrome's stack trace in the admin UI.
  defp flaresolverr_error(definition_id, reason) do
    Logger.error("FlareSolverr failed for #{definition_id}: #{inspect(reason)}")
    reason_error(reason)
  end

  defp reason_error({:browser_crashed, _}) do
    Error.connection_failed(
      "FlareSolverr: browser tab crashed (FlareSolverr's Chrome ran out of resources; " <>
        "lower flaresolverr.max_concurrent_requests or give FlareSolverr more memory)"
    )
  end

  defp reason_error({:cookie_rejected, message}),
    do: Error.connection_failed("FlareSolverr: Chrome rejected a cookie (#{message})")

  defp reason_error({:challenge_timeout, _}),
    do: Error.connection_failed("FlareSolverr: timed out solving the challenge")

  defp reason_error({category, message}) when is_atom(category) and is_binary(message),
    do: Error.connection_failed("FlareSolverr: #{message}")

  defp reason_error(:timeout), do: Error.connection_failed("FlareSolverr: request timed out")

  defp reason_error(:flaresolverr_busy) do
    Error.connection_failed(
      "FlareSolverr: busy with other indexers; no request slot freed up in time"
    )
  end

  defp reason_error({:connection_error, conn_reason}),
    do: Error.connection_failed("FlareSolverr: unreachable (#{inspect(conn_reason)})")

  defp reason_error({:http_error, status, _body}),
    do: Error.connection_failed("FlareSolverr: HTTP #{status}")

  defp reason_error(other), do: Error.search_failed("FlareSolverr: #{inspect(other)}")

  # Append query params to URL
  defp append_query_params(url, params) when params == %{}, do: url

  defp append_query_params(url, params) do
    query_string =
      params
      |> Enum.map_join("&", fn {k, v} ->
        "#{URI.encode_www_form(to_string(k))}=#{URI.encode_www_form(to_string(v))}"
      end)

    if String.contains?(url, "?") do
      "#{url}&#{query_string}"
    else
      "#{url}?#{query_string}"
    end
  end

  # Convert FlareSolverr headers to list format
  defp convert_flaresolverr_headers(%FlareSolverrResponse{solution: %{headers: headers}})
       when is_map(headers) do
    Enum.map(headers, fn {k, v} -> {k, v} end)
  end

  defp convert_flaresolverr_headers(_), do: []
end
