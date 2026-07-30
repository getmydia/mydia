defmodule Mydia.Downloads.Client.Debrid.Providers.TorBox do
  @moduledoc """
  TorBox provider for the debrid download client.

  ## Validation status

  **Bypass-only** — no real-account validation. Tests cover documented
  API shapes per https://api-docs.torbox.app/. Please open a Mydia issue
  if you hit unexpected behavior with a live TorBox subscription.

  ## API quirks

  - Auth is `Authorization: Bearer <key>` on most endpoints, except
    `/torrents/requestdl` which uses `?token=<key>` as a query param.
  - Ready predicate is the boolean pair `download_finished &&
    download_present`, NOT `download_state == "completed"` (docs
    explicitly warn against the latter).
  - Single batch endpoint `GET /torrents/mylist?bypass_cache=true`
    returns the full account torrent list — efficient `list_jobs/2`.
  - 300 req/min per endpoint.

  ## R8 descriptors (tokenless)

  `get_download_urls/2` returns capability descriptors instead of URLs:

      %{"provider" => "torbox", "torrent_id" => N, "file_id" => N}

  The token-bearing URL is reconstructed by the Fetcher at fetch time
  from `config.api_key` via `materialize_descriptor/2`. This guarantees
  the operator's API token never sits in `Download.metadata["debrid_urls"]`
  rows, log lines, or error envelopes that mention persisted URLs.
  """

  @behaviour Mydia.Downloads.Client.Debrid.Provider

  alias Mydia.Downloads.Client.Debrid.{ProviderJob, Shared}
  alias Mydia.Downloads.Client.Error
  alias Mydia.Downloads.Client.Helpers
  alias Mydia.Downloads.Structs.ClientInfo

  @default_base_url "https://api.torbox.app/v1/api"

  defp base_url, do: Application.get_env(:mydia, :tor_box_base_url, @default_base_url)

  defp auth_headers(%{api_key: key}) when is_binary(key),
    do: [{"authorization", "Bearer #{key}"}]

  defp auth_headers(_), do: []

  @impl true
  def rate_limit_budget, do: {300, 60}

  @impl true
  def validate_credentials(config) do
    case Req.get(base_url() <> "/user/me",
           params: %{settings: true},
           headers: auth_headers(config)
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case wrap_tb(body) do
          {:ok, %{"plan" => plan, "premium_expires_at" => expiry}}
          when is_integer(plan) and plan > 0 and is_binary(expiry) ->
            {:ok, %ClientInfo{version: "TorBox (plan #{plan})", api_version: "v1"}}

          {:ok, _} ->
            {:error,
             Error.authentication_failed("TorBox plan not active", %{reason: :plan_limit})}

          {:error, err} ->
            {:error, err}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, build_error(status, body, config)}

      {:error, %Req.TransportError{} = err} ->
        {:error, Error.from_req_error(err)}
    end
  end

  @impl true
  def submit_torrent(config, input) do
    case Req.post(base_url() <> "/torrents/createtorrent",
           form_multipart: torrent_multipart(input),
           headers: auth_headers(config)
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case wrap_tb(body) do
          {:ok, %{"torrent_id" => id}} ->
            {:ok, to_string(id)}

          {:error, err} ->
            {:error, err}

          _ ->
            {:error,
             Error.parse_error("Unexpected TB createtorrent shape", %{
               body: sanitize(body, config)
             })}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, build_error(status, body, config)}

      {:error, %Req.TransportError{} = err} ->
        {:error, Error.from_req_error(err)}
    end
  end

  defp torrent_multipart({:magnet, magnet}), do: [magnet: magnet]

  defp torrent_multipart({:file, bin}) do
    [
      file: {bin, filename: "release.torrent", content_type: "application/x-bittorrent"}
    ]
  end

  @impl true
  def post_submission_setup(_config, _id), do: :ok

  @impl true
  def get_job(config, provider_job_id) do
    case Req.get(base_url() <> "/torrents/mylist",
           params: %{id: provider_job_id, bypass_cache: true},
           headers: auth_headers(config)
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case wrap_tb(body) do
          {:ok, %{} = torrent} -> {:ok, parse_torrent(torrent)}
          {:error, err} -> {:error, err}
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

    case Req.get(base_url() <> "/torrents/mylist",
           params: %{bypass_cache: true},
           headers: auth_headers(config)
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case wrap_tb(body) do
          {:ok, list} when is_list(list) ->
            result =
              list
              |> Enum.filter(fn t -> to_string(t["id"]) in requested end)
              |> Map.new(fn t ->
                job = parse_torrent(t)
                {job.provider_id, job}
              end)

            {:ok, result}

          {:error, err} ->
            {:error, err}

          _ ->
            {:error,
             Error.parse_error("Unexpected TB mylist shape", %{body: sanitize(body, config)})}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, build_error(status, body, config)}

      {:error, %Req.TransportError{} = err} ->
        {:error, Error.from_req_error(err)}
    end
  end

  @impl true
  def get_download_urls(_config, %ProviderJob{provider_id: torrent_id, raw_status: raw}) do
    files = raw["files"] || []

    descriptors =
      Enum.map(files, fn f ->
        %{"provider" => "torbox", "torrent_id" => parse_int(torrent_id), "file_id" => f["id"]}
      end)

    {:ok, descriptors}
  end

  @doc """
  Reconstructs the token-bearing `requestdl` URL from a tokenless
  descriptor. Called by the Fetcher *at fetch time* with the live
  `config.api_key`. The reconstructed URL is then validated by
  `Shared.validate_download_url/1` before any HTTP call.
  """
  @spec materialize_descriptor(map(), map()) :: {:ok, String.t()} | {:error, Error.t()}
  def materialize_descriptor(%{api_key: key} = _config, %{
        "torrent_id" => torrent_id,
        "file_id" => file_id
      })
      when is_binary(key) do
    url =
      base_url() <>
        "/torrents/requestdl?" <>
        URI.encode_query(%{
          token: key,
          torrent_id: torrent_id,
          file_id: file_id,
          redirect: true
        })

    {:ok, url}
  end

  def materialize_descriptor(_config, _descriptor) do
    {:error, Error.invalid_config("TorBox config missing api_key for descriptor reconstruction")}
  end

  @impl true
  def delete_job(config, provider_job_id) do
    case Req.post(base_url() <> "/torrents/controltorrent",
           json: %{torrent_id: parse_int(provider_job_id), operation: "delete"},
           headers: auth_headers(config)
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case wrap_tb(body) do
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

  ## ── Parsing ─────────────────────────────────────────────────────────

  defp parse_torrent(%{} = t) do
    native_state = t["download_state"]

    state =
      if t["download_finished"] == true and t["download_present"] == true do
        :ready
      else
        map_download_state(native_state)
      end

    {category, detail} = classify_failure(state, native_state)

    %ProviderJob{
      provider_id: to_string(t["id"]),
      state: state,
      progress: (t["progress"] || 0.0) * 100.0,
      name: t["name"],
      total_bytes: t["size"] || 0,
      files: t["files"] || [],
      hoster_links: [],
      raw_status: t,
      failure_category: category,
      failure_detail: detail
    }
  end

  defp map_download_state("queuedDL"), do: :queued
  defp map_download_state("paused"), do: :queued
  defp map_download_state("downloading"), do: :downloading
  defp map_download_state("metaDL"), do: :downloading
  defp map_download_state("checking"), do: :downloading
  defp map_download_state("checkingResumeData"), do: :downloading
  defp map_download_state("stalledDL"), do: :downloading
  defp map_download_state("stalled (no seeds)"), do: :downloading
  defp map_download_state("allocating"), do: :downloading
  defp map_download_state("completed"), do: :finalizing
  defp map_download_state("cached"), do: :finalizing
  defp map_download_state("uploading"), do: :finalizing
  defp map_download_state("error"), do: :error
  defp map_download_state("missingFiles"), do: :error
  defp map_download_state(_), do: :queued

  # Only terminal states carry a classification. The detail is the native
  # `download_state` string itself — never the surrounding payload, whose
  # `files` entries carry credentialed CDN URLs.
  defp classify_failure(:error, native_state) when is_binary(native_state) do
    {failure_category(native_state), Helpers.sanitize_failure_detail(native_state)}
  end

  defp classify_failure(_state, _native_state), do: {nil, nil}

  defp failure_category("missingFiles"), do: :missing_files
  defp failure_category("error"), do: :provider_error
  defp failure_category(_), do: nil

  defp parse_int(n) when is_integer(n), do: n

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> s
    end
  end

  ## ── Envelope wrapper ────────────────────────────────────────────────

  defp wrap_tb(%{"success" => true, "data" => data}), do: {:ok, data}

  defp wrap_tb(%{"success" => false} = body) do
    code = body["error"] || body["detail"] || "UNKNOWN_ERROR"
    {:error, error_for_code(code, body)}
  end

  defp wrap_tb(other), do: {:error, Error.parse_error("Unexpected TB envelope", %{body: other})}

  defp error_for_code(code, body) do
    case code do
      c when c in ["BAD_TOKEN", "AUTH_ERROR", "NO_AUTH"] ->
        Error.authentication_failed("TB auth failed", %{code: c, body: body})

      c when c in ["PLAN_RESTRICTED_FEATURE", "MONTHLY_LIMIT"] ->
        Error.authentication_failed("TB plan limit", %{code: c, reason: :plan_limit})

      "ACTIVE_LIMIT" ->
        Error.api_error("TB active limit", %{reason: :slot_limit, body: body})

      "DOWNLOAD_TOO_LARGE" ->
        Error.invalid_torrent("TB download too large", %{body: body})

      c when c in ["DATABASE_ERROR", "UNKNOWN_ERROR", "DOWNLOAD_SERVER_ERROR"] ->
        Error.network_error("TB upstream error", %{code: c, body: body})

      _ ->
        Error.api_error("TB error: #{inspect(code)}", %{code: code, body: body})
    end
  end

  ## ── HTTP error mapping ──────────────────────────────────────────────

  defp build_error(429, _body, _config),
    do: Error.api_error("TB rate-limited", %{reason: :rate_limited})

  defp build_error(401, body, config),
    do: Error.authentication_failed("TB auth failed", %{body: sanitize(body, config)})

  defp build_error(403, body, config) do
    case body do
      %{"error" => "ACTIVE_LIMIT"} ->
        Error.api_error("TB active limit", %{reason: :slot_limit, body: sanitize(body, config)})

      _ ->
        Error.authentication_failed("TB forbidden", %{body: sanitize(body, config)})
    end
  end

  defp build_error(status, body, config),
    do: Error.api_error("TB HTTP #{status}", %{body: sanitize(body, config)})

  defp sanitize(body, config), do: Shared.sanitize_error_body(body, config)
end
