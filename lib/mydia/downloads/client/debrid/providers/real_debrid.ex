defmodule Mydia.Downloads.Client.Debrid.Providers.RealDebrid do
  @moduledoc """
  Real-Debrid provider for the debrid download client.

  ## Validation status

  This is the only provider tested against a real subscription during
  development. Test surface combines Bypass-based per-endpoint unit tests
  with manual real-account validation. See the @manual_real_account_*
  notes below.

  ## API quirks

  - `selectFiles=all` is **mandatory** after `addMagnet`/`addTorrent`,
    or the torrent sits forever in `waiting_files_selection`.
  - `instantAvailability` was removed in November 2024; the plan
    explicitly does not depend on cache pre-checks.
  - `/unrestrict/link` is the gate for hoster-link resolution; rate-limited
    harder than the rest of the API.
  - URLs returned by `/unrestrict/link` are IP-bound and ~1 week lived.
    Fetcher.init/1 always re-resolves on restart.
  - 250 req/min budget shared across all endpoints.
  - No batch endpoint for torrent info → `list_jobs/2` falls back to N
    concurrent `get_job/2` calls under the rate limiter.

  ## Manual real-account validation

  Documented in the test file's `@manual_real_account_steps` doc-string.
  """

  @behaviour Mydia.Downloads.Client.Debrid.Provider

  alias Mydia.Downloads.Client.Debrid.{ProviderJob, Shared}
  alias Mydia.Downloads.Client.Error
  alias Mydia.Downloads.Client.Helpers
  alias Mydia.Downloads.Structs.ClientInfo

  @default_base_url "https://api.real-debrid.com/rest/1.0"

  defp base_url do
    Application.get_env(:mydia, :real_debrid_base_url, @default_base_url)
  end

  defp auth_headers(%{api_key: key}) when is_binary(key) do
    [{"authorization", "Bearer #{key}"}]
  end

  defp auth_headers(_), do: []

  @impl true
  def rate_limit_budget, do: {250, 60}

  @impl true
  def validate_credentials(config) do
    case Req.get(base_url() <> "/user", headers: auth_headers(config)) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case body do
          %{"type" => "premium", "premium" => premium} when premium > 0 ->
            {:ok, %ClientInfo{version: "Real-Debrid (premium)", api_version: "1.0"}}

          %{"type" => other} ->
            {:error,
             Error.authentication_failed("Real-Debrid subscription not premium", %{
               type: other,
               reason: :subscription_expired
             })}

          _ ->
            {:error, Error.parse_error("Unexpected /user response", %{body: body})}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, build_error(status, body, config)}

      {:error, %Req.TransportError{} = err} ->
        {:error, Error.from_req_error(err)}
    end
  end

  @impl true
  def submit_torrent(config, {:magnet, magnet}) do
    case Req.post(base_url() <> "/torrents/addMagnet",
           form: [magnet: magnet],
           headers: auth_headers(config)
         ) do
      {:ok, %Req.Response{status: 201, body: %{"id" => id}}} ->
        {:ok, to_string(id)}

      {:ok, %Req.Response{status: 200, body: %{"id" => id}}} ->
        # Some accounts return 200 even though docs say 201.
        {:ok, to_string(id)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, build_error(status, body, config)}

      {:error, %Req.TransportError{} = err} ->
        {:error, Error.from_req_error(err)}
    end
  end

  def submit_torrent(config, {:file, bin}) do
    case Req.put(base_url() <> "/torrents/addTorrent",
           body: bin,
           headers: [{"content-type", "application/x-bittorrent"} | auth_headers(config)]
         ) do
      {:ok, %Req.Response{status: status, body: %{"id" => id}}} when status in 200..299 ->
        {:ok, to_string(id)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, build_error(status, body, config)}

      {:error, %Req.TransportError{} = err} ->
        {:error, Error.from_req_error(err)}
    end
  end

  @impl true
  def post_submission_setup(config, provider_job_id) do
    case Req.post(base_url() <> "/torrents/selectFiles/" <> provider_job_id,
           form: [files: "all"],
           headers: auth_headers(config)
         ) do
      {:ok, %Req.Response{status: status}} when status in [200, 204] ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, build_error(status, body, config)}

      {:error, %Req.TransportError{} = err} ->
        {:error, Error.from_req_error(err)}
    end
  end

  @impl true
  def get_job(config, provider_job_id) do
    case Req.get(base_url() <> "/torrents/info/" <> provider_job_id,
           headers: auth_headers(config)
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, parse_torrent_info(provider_job_id, body)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, build_error(status, body, config)}

      {:error, %Req.TransportError{} = err} ->
        {:error, Error.from_req_error(err)}
    end
  end

  @impl true
  def list_jobs(_config, []), do: {:ok, %{}}

  def list_jobs(config, provider_job_ids) do
    # No batch endpoint. Fan out concurrent get_job calls under a
    # bounded parallelism. Each sub-request acquires its own rate-limit
    # slot so that the full fan-out count is accurately tracked against
    # the 250/min provider budget.
    budget = rate_limit_budget()
    api_key = config[:api_key] || ""

    results =
      provider_job_ids
      |> Task.async_stream(
        fn id ->
          alias Mydia.Downloads.Client.Debrid.RateLimiter

          case RateLimiter.acquire(:real_debrid, api_key, budget) do
            :ok ->
              case get_job(config, id) do
                {:ok, job} -> {id, {:ok, job}}
                {:error, %Error{} = err} -> {id, {:error, err}}
              end

            {:error, :rate_limited} ->
              {id,
               {:error,
                Error.api_error("Real-Debrid rate limited on list_jobs sub-request", %{
                  reason: :rate_limited
                })}}
          end
        end,
        timeout: :infinity,
        max_concurrency: 8,
        ordered: false
      )
      |> Enum.reduce(%{}, fn
        {:ok, {id, {:ok, job}}}, acc -> Map.put(acc, id, job)
        # Skip per-job errors silently — they surface on the next tick.
        _, acc -> acc
      end)

    {:ok, results}
  end

  @impl true
  def get_download_urls(config, %ProviderJob{hoster_links: links, raw_status: raw}) do
    candidate_links = links || extract_links_from_raw(raw)
    unrestrict_links(config, candidate_links)
  end

  defp unrestrict_links(config, links) do
    Enum.reduce_while(links, {:ok, []}, fn link, {:ok, acc} ->
      case Req.post(base_url() <> "/unrestrict/link",
             form: [link: link],
             headers: auth_headers(config)
           ) do
        {:ok, %Req.Response{status: 200, body: %{"download" => url}}} when is_binary(url) ->
          {:cont, {:ok, [url | acc]}}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:halt, {:error, build_error(status, body, config)}}

        {:error, %Req.TransportError{} = err} ->
          {:halt, {:error, Error.from_req_error(err)}}
      end
    end)
    |> case do
      {:ok, urls} -> {:ok, Enum.reverse(urls)}
      err -> err
    end
  end

  defp extract_links_from_raw(%{"links" => links}) when is_list(links), do: links
  defp extract_links_from_raw(_), do: []

  @impl true
  def delete_job(config, provider_job_id) do
    case Req.delete(base_url() <> "/torrents/delete/" <> provider_job_id,
           headers: auth_headers(config)
         ) do
      {:ok, %Req.Response{status: status}} when status in [200, 204] ->
        :ok

      {:ok, %Req.Response{status: 404}} ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, build_error(status, body, config)}

      {:error, %Req.TransportError{} = err} ->
        {:error, Error.from_req_error(err)}
    end
  end

  ## ── Parsing ─────────────────────────────────────────────────────────

  defp parse_torrent_info(id, body) do
    native_status = body["status"]
    state = map_status(native_status)
    {category, detail} = classify_failure(state, native_status)

    %ProviderJob{
      provider_id: id,
      state: state,
      progress: (body["progress"] || 0.0) * 1.0,
      name: body["filename"],
      total_bytes: body["bytes"] || 0,
      files: body["files"] || [],
      hoster_links: body["links"] || [],
      raw_status: body,
      failure_category: category,
      failure_detail: detail
    }
  end

  defp map_status("magnet_conversion"), do: :queued
  defp map_status("queued"), do: :queued
  defp map_status("waiting_files_selection"), do: :queued
  defp map_status("downloading"), do: :downloading
  defp map_status("compressing"), do: :finalizing
  defp map_status("uploading"), do: :finalizing
  defp map_status("downloaded"), do: :ready
  defp map_status("error"), do: :error
  defp map_status("virus"), do: :error
  defp map_status("dead"), do: :error
  defp map_status("magnet_error"), do: :error
  defp map_status(_), do: :queued

  # The detail is the native status string alone — never the body, whose
  # `links` are credentialed CDN URLs.
  defp classify_failure(:error, native_status) when is_binary(native_status) do
    {failure_category(native_status), Helpers.sanitize_failure_detail(native_status)}
  end

  defp classify_failure(_state, _native_status), do: {nil, nil}

  defp failure_category("dead"), do: :no_peers
  defp failure_category("virus"), do: :rejected_content
  defp failure_category("magnet_error"), do: :rejected_content
  defp failure_category("error"), do: :provider_error
  defp failure_category(_), do: nil

  ## ── Error mapping ────────────────────────────────────────────────────

  defp build_error(status, body, config) do
    sanitized = Shared.sanitize_error_body(body, config)
    code = extract_error_code(body)

    case {status, code} do
      # error_code clauses come first — RD often returns 404 + a specific
      # error_code, and the code is more diagnostic than the HTTP status.
      {_, 8} ->
        Error.authentication_failed("RD bad token", merge_details(sanitized, code))

      {_, 7} ->
        # "unknown_ressource" — most commonly seen when an addMagnet
        # successfully returns an id, but RD's anti-piracy auto-review
        # then deletes the torrent before selectFiles or info can act
        # on it. The id is real but the resource is gone. From the
        # operator's perspective this is identical to an infringing
        # rejection: skip the release, try the next one.
        Error.invalid_torrent(
          "RD rejected the torrent after acceptance",
          merge_details(sanitized, code, :rejected_after_acceptance)
        )

      {401, _} ->
        Error.authentication_failed("RD auth failed", merge_details(sanitized, code))

      {403, _} ->
        Error.authentication_failed("RD access forbidden", merge_details(sanitized, code))

      {429, _} ->
        Error.api_error("rate-limited", merge_details(sanitized, code, :rate_limited))

      {404, _} ->
        Error.not_found("RD resource not found", merge_details(sanitized, code))

      {503, _} ->
        Error.network_error("RD upstream unavailable", merge_details(sanitized, code))

      {_, 9} ->
        Error.authentication_failed(
          "RD permission denied",
          merge_details(sanitized, code, :permission_denied)
        )

      {_, 14} ->
        Error.authentication_failed(
          "RD permission denied",
          merge_details(sanitized, code, :permission_denied)
        )

      {_, 21} ->
        Error.api_error("RD active slot limit", merge_details(sanitized, code, :slot_limit))

      {_, 23} ->
        Error.api_error("RD quota exhausted", merge_details(sanitized, code, :quota_exhausted))

      {_, 36} ->
        Error.api_error("RD quota exhausted", merge_details(sanitized, code, :quota_exhausted))

      {_, 33} ->
        Error.duplicate_torrent("RD duplicate", merge_details(sanitized, code))

      {_, 34} ->
        Error.api_error("RD rate-limited", merge_details(sanitized, code, :rate_limited))

      {_, 5} ->
        Error.api_error("RD rate-limited", merge_details(sanitized, code, :rate_limited))

      {_, 35} ->
        Error.invalid_torrent("RD infringing", merge_details(sanitized, code, :infringing))

      {_, 25} ->
        Error.network_error("RD network error", merge_details(sanitized, code))

      {status, _} when status >= 500 ->
        Error.network_error("RD upstream error #{status}", merge_details(sanitized, code))

      _ ->
        Error.api_error("RD HTTP #{status}", merge_details(sanitized, code))
    end
  end

  defp extract_error_code(%{"error_code" => code}) when is_integer(code), do: code
  defp extract_error_code(_), do: nil

  defp merge_details(body, code, reason \\ nil) do
    base = %{body: body}
    base = if code, do: Map.put(base, :error_code, code), else: base
    if reason, do: Map.put(base, :reason, reason), else: base
  end
end
