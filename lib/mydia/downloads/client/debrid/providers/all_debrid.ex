defmodule Mydia.Downloads.Client.Debrid.Providers.AllDebrid do
  @moduledoc """
  AllDebrid provider for the debrid download client.

  ## Validation status

  **Bypass-only** — no real-account validation. Tests cover documented
  API shapes per https://docs.alldebrid.com/. Please open a Mydia issue
  if you hit unexpected behavior with a live AllDebrid subscription.

  ## API quirks

  - Post-2025 auth migration: `Authorization: Bearer <key>` header is now
    the default; legacy `?apikey=` query-param is ignored here.
  - AllDebrid returns HTTP 200 even on logical errors; the wrapper checks
    `status` in the JSON body before treating it as success.
  - `statusCode` is an integer enum (0–15); `magnet/files` returns
    pre-unlocked URLs (no separate unrestrict step).
  - 12 req/sec + 600 req/min budget; we model just the per-minute cap.
  - Single batch endpoint `POST /v4.1/magnet/status` returns the full
    account magnet list when called without an `id` — efficient `list_jobs`.
  """

  @behaviour Mydia.Downloads.Client.Debrid.Provider

  alias Mydia.Downloads.Client.Debrid.{ProviderJob, Shared}
  alias Mydia.Downloads.Client.Error
  alias Mydia.Downloads.Client.Helpers
  alias Mydia.Downloads.Structs.ClientInfo

  @default_base_url "https://api.alldebrid.com"

  defp base_url, do: Application.get_env(:mydia, :all_debrid_base_url, @default_base_url)

  defp auth_headers(%{api_key: key}) when is_binary(key),
    do: [{"authorization", "Bearer #{key}"}]

  defp auth_headers(_), do: []

  @impl true
  def rate_limit_budget, do: {600, 60}

  @impl true
  def validate_credentials(config) do
    case Req.get(base_url() <> "/v4/user", headers: auth_headers(config)) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case wrap_ad(body) do
          {:ok, %{"user" => %{"isPremium" => true, "premiumUntil" => until}}} when until > 0 ->
            {:ok, %ClientInfo{version: "AllDebrid (premium)", api_version: "v4"}}

          {:ok, %{"user" => %{"isPremium" => false}}} ->
            {:error,
             Error.authentication_failed("AllDebrid subscription not premium", %{
               reason: :subscription_required
             })}

          {:error, %Error{} = err} ->
            {:error, err}

          _ ->
            {:error,
             Error.parse_error("Unexpected AD /user shape", %{body: sanitize(body, config)})}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, build_error(status, body, config)}

      {:error, %Req.TransportError{} = err} ->
        {:error, Error.from_req_error(err)}
    end
  end

  @impl true
  def submit_torrent(config, {:magnet, magnet}) do
    case Req.post(base_url() <> "/v4/magnet/upload",
           form: [{"magnets[]", magnet}],
           headers: auth_headers(config)
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case wrap_ad(body) do
          {:ok, %{"magnets" => [%{"id" => id} | _]}} ->
            {:ok, to_string(id)}

          {:error, %Error{} = err} ->
            {:error, err}

          _ ->
            {:error,
             Error.parse_error("Unexpected AD magnet/upload shape", %{
               body: sanitize(body, config)
             })}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, build_error(status, body, config)}

      {:error, %Req.TransportError{} = err} ->
        {:error, Error.from_req_error(err)}
    end
  end

  def submit_torrent(config, {:file, bin}) do
    case Req.post(base_url() <> "/v4/magnet/upload/file",
           form_multipart: [
             {:"files[]",
              {bin, filename: "release.torrent", content_type: "application/x-bittorrent"}}
           ],
           headers: auth_headers(config)
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case wrap_ad(body) do
          {:ok, %{"files" => [%{"id" => id} | _]}} ->
            {:ok, to_string(id)}

          {:ok, %{"magnets" => [%{"id" => id} | _]}} ->
            {:ok, to_string(id)}

          {:error, %Error{} = err} ->
            {:error, err}

          _ ->
            {:error,
             Error.parse_error("Unexpected AD magnet/upload/file shape", %{
               body: sanitize(body, config)
             })}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, build_error(status, body, config)}

      {:error, %Req.TransportError{} = err} ->
        {:error, Error.from_req_error(err)}
    end
  end

  @impl true
  def post_submission_setup(_config, _id), do: :ok

  @impl true
  def get_job(config, provider_job_id) do
    case Req.post(base_url() <> "/v4.1/magnet/status",
           form: [{"id", provider_job_id}],
           headers: auth_headers(config)
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case wrap_ad(body) do
          {:ok, %{"magnets" => magnet}} when is_map(magnet) ->
            {:ok, parse_magnet(magnet)}

          {:ok, %{"magnets" => [magnet | _]}} ->
            {:ok, parse_magnet(magnet)}

          {:error, %Error{} = err} ->
            {:error, err}

          _ ->
            {:error,
             Error.parse_error("Unexpected AD magnet/status shape", %{
               body: sanitize(body, config)
             })}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, build_error(status, body, config)}

      {:error, %Req.TransportError{} = err} ->
        {:error, Error.from_req_error(err)}
    end
  end

  @impl true
  def list_jobs(_config, []), do: {:ok, %{}}

  def list_jobs(config, provider_job_ids) do
    requested = MapSet.new(provider_job_ids)

    case Req.post(base_url() <> "/v4.1/magnet/status",
           form: [],
           headers: auth_headers(config)
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case wrap_ad(body) do
          {:ok, %{"magnets" => list}} when is_list(list) ->
            result =
              list
              |> Enum.filter(fn m -> to_string(m["id"]) in requested end)
              |> Map.new(fn m ->
                job = parse_magnet(m)
                {job.provider_id, job}
              end)

            {:ok, result}

          {:error, %Error{} = err} ->
            {:error, err}

          _ ->
            {:error,
             Error.parse_error("Unexpected AD magnet/status list shape", %{
               body: sanitize(body, config)
             })}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, build_error(status, body, config)}

      {:error, %Req.TransportError{} = err} ->
        {:error, Error.from_req_error(err)}
    end
  end

  @impl true
  def get_download_urls(config, %ProviderJob{provider_id: id}) do
    case Req.post(base_url() <> "/v4/magnet/files",
           form: [{"id[]", id}],
           headers: auth_headers(config)
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case wrap_ad(body) do
          {:ok, %{"magnets" => [%{"files" => files} | _]}} ->
            {:ok, flatten_files(files)}

          {:ok, %{"magnets" => %{"files" => files}}} ->
            {:ok, flatten_files(files)}

          {:error, %Error{} = err} ->
            {:error, err}

          _ ->
            {:error,
             Error.parse_error("Unexpected AD magnet/files shape", %{body: sanitize(body, config)})}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, build_error(status, body, config)}

      {:error, %Req.TransportError{} = err} ->
        {:error, Error.from_req_error(err)}
    end
  end

  @impl true
  def delete_job(config, provider_job_id) do
    case Req.post(base_url() <> "/v4/magnet/delete",
           form: [{"id", provider_job_id}],
           headers: auth_headers(config)
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case wrap_ad(body) do
          {:ok, _} -> :ok
          {:error, %Error{type: :not_found}} -> :ok
          {:error, err} -> {:error, err}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, build_error(status, body, config)}

      {:error, %Req.TransportError{} = err} ->
        {:error, Error.from_req_error(err)}
    end
  end

  ## ── Parsing helpers ─────────────────────────────────────────────────

  defp flatten_files(files) when is_list(files) do
    files
    |> Enum.flat_map(&extract_urls/1)
  end

  defp extract_urls(%{"l" => url}) when is_binary(url), do: [url]
  defp extract_urls(%{"e" => children}) when is_list(children), do: flatten_files(children)
  defp extract_urls(_), do: []

  defp parse_magnet(%{} = m) do
    state = map_status_code(m["statusCode"])
    {category, detail} = classify_failure(state, m)

    %ProviderJob{
      provider_id: to_string(m["id"]),
      state: state,
      progress: progress(m),
      name: m["filename"],
      total_bytes: m["size"] || 0,
      files: m["files"] || [],
      hoster_links: [],
      raw_status: m,
      failure_category: category,
      failure_detail: detail
    }
  end

  defp progress(%{"downloaded" => d, "size" => s}) when is_number(d) and is_number(s) and s > 0,
    do: d / s * 100.0

  defp progress(_), do: 0.0

  defp map_status_code(0), do: :queued
  defp map_status_code(1), do: :downloading
  defp map_status_code(code) when code in [2, 3], do: :finalizing
  defp map_status_code(4), do: :ready
  defp map_status_code(code) when is_integer(code) and code >= 5, do: :error
  defp map_status_code(_), do: :queued

  defp classify_failure(:error, %{} = m) do
    {failure_category(m["statusCode"]), failure_detail(m)}
  end

  defp classify_failure(_state, _m), do: {nil, nil}

  # Documented AllDebrid terminal codes. `map_status_code/1` already treats
  # anything >= 5 as terminal, so codes beyond this table stay terminal and
  # simply carry no category rather than a guessed one.
  defp failure_category(code) when code in [5, 6, 9], do: :provider_error
  defp failure_category(code) when code in [7, 10], do: :no_peers
  defp failure_category(8), do: :rejected_content
  defp failure_category(11), do: :missing_files
  defp failure_category(_), do: nil

  defp failure_detail(%{"status" => status}) when is_binary(status) and status != "" do
    Helpers.sanitize_failure_detail(status)
  end

  defp failure_detail(%{"statusCode" => code}) when is_integer(code) do
    Helpers.sanitize_failure_detail("statusCode #{code}")
  end

  defp failure_detail(_), do: nil

  ## ── 200-on-error wrapper ────────────────────────────────────────────

  defp wrap_ad(%{"status" => "success", "data" => data}), do: {:ok, data}

  defp wrap_ad(%{"status" => "error", "error" => %{"code" => code} = err_body}) do
    {:error, error_for_code(code, err_body)}
  end

  defp wrap_ad(other) do
    {:error, Error.parse_error("Unexpected AD envelope", %{body: other})}
  end

  defp error_for_code(code, body) do
    case code do
      c when c in ["AUTH_BAD_APIKEY", "AUTH_MISSING_APIKEY"] ->
        Error.authentication_failed("AD bad/missing API key", %{code: code, body: body})

      c when c in ["AUTH_BLOCKED", "AUTH_USER_BANNED"] ->
        Error.authentication_failed("AD account blocked", %{code: code, reason: :account_blocked})

      c when c in ["MUST_BE_PREMIUM", "MAGNET_MUST_BE_PREMIUM"] ->
        Error.authentication_failed("AD premium required", %{
          code: code,
          reason: :subscription_required
        })

      c when c in ["MAGNET_INVALID_URI", "MAGNET_INVALID_FILE"] ->
        Error.invalid_torrent("AD invalid magnet/file", %{code: code})

      "MAGNET_INVALID_ID" ->
        Error.not_found("AD magnet not found", %{code: code})

      c when c in ["MAGNET_TOO_MANY_ACTIVE", "MAGNET_TOO_MANY"] ->
        Error.api_error("AD slot limit", %{code: code, reason: :slot_limit})

      _ ->
        Error.api_error("AD error: #{code}", %{code: code, body: body})
    end
  end

  ## ── HTTP error mapping ──────────────────────────────────────────────

  defp build_error(429, _body, config) do
    Error.api_error("AD rate-limited", %{reason: :rate_limited, sanitized: sanitize(%{}, config)})
  end

  defp build_error(503, _body, _config) do
    Error.network_error("AD upstream unavailable")
  end

  defp build_error(status, body, config) do
    Error.api_error("AD HTTP #{status}", %{body: sanitize(body, config)})
  end

  defp sanitize(body, config), do: Shared.sanitize_error_body(body, config)
end
