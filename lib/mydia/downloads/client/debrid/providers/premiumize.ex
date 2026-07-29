defmodule Mydia.Downloads.Client.Debrid.Providers.Premiumize do
  @moduledoc """
  Premiumize provider for the debrid download client.

  ## Validation status

  **Bypass-only** — no real-account validation. Tests cover documented
  API shapes per https://www.premiumize.me/api. Please open a Mydia issue
  if you hit unexpected behavior with a live Premiumize subscription.

  ## API quirks

  - No per-id GET — `get_job/2` calls `/transfer/list` and filters.
  - List-only `list_jobs/2` is the natural batch primitive.
  - 200-on-error envelope (`status: "error"`).
  - File transfers expose `file_id`; folder transfers expose `folder_id`
    and require recursive walking via `/folder/list`.
  - Rate-limit documentation is opaque; we start conservative at
    {30, 60} and the operator can override if needed.
  - Returns plain HTTPS URLs (no separate unrestrict step).
  """

  @behaviour Mydia.Downloads.Client.Debrid.Provider

  alias Mydia.Downloads.Client.Debrid.{ProviderJob, Shared}
  alias Mydia.Downloads.Client.Error
  alias Mydia.Downloads.Structs.ClientInfo

  @default_base_url "https://www.premiumize.me/api"

  defp base_url, do: Application.get_env(:mydia, :premiumize_base_url, @default_base_url)

  defp auth_headers(%{api_key: key}) when is_binary(key),
    do: [{"authorization", "Bearer #{key}"}]

  defp auth_headers(_), do: []

  @impl true
  def rate_limit_budget, do: {30, 60}

  @impl true
  def validate_credentials(config) do
    case Req.get(base_url() <> "/account/info", headers: auth_headers(config)) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case wrap_pm(body, config) do
          {:ok, data} ->
            case data["premium_until"] do
              n when is_integer(n) and n > 0 ->
                {:ok, %ClientInfo{version: "Premiumize (premium)", api_version: "v1"}}

              _ ->
                {:error,
                 Error.authentication_failed("Premiumize subscription expired", %{
                   reason: :subscription_required
                 })}
            end

          {:error, %Error{} = err} ->
            {:error, err}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, build_error(status, body, config)}

      {:error, %Req.TransportError{} = err} ->
        {:error, Error.from_req_error(err)}
    end
  end

  @impl true
  def submit_torrent(config, {:magnet, magnet}) do
    case Req.post(base_url() <> "/transfer/create",
           form: [{"src", magnet}],
           headers: auth_headers(config)
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case wrap_pm(body, config) do
          {:ok, %{"id" => id}} ->
            {:ok, to_string(id)}

          {:error, %Error{} = err} ->
            {:error, err}

          _ ->
            {:error,
             Error.parse_error("Unexpected PM transfer/create shape", %{
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
    case Req.post(base_url() <> "/transfer/create",
           form_multipart: [
             src: {bin, filename: "release.torrent", content_type: "application/x-bittorrent"}
           ],
           headers: auth_headers(config)
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case wrap_pm(body, config) do
          {:ok, %{"id" => id}} ->
            {:ok, to_string(id)}

          {:error, err} ->
            {:error, err}

          _ ->
            {:error,
             Error.parse_error("Unexpected PM transfer/create file shape", %{
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
    case list_transfers(config) do
      {:ok, transfers} ->
        case Enum.find(transfers, fn t -> to_string(t["id"]) == provider_job_id end) do
          nil -> {:error, Error.not_found("PM transfer not found", %{id: provider_job_id})}
          t -> {:ok, parse_transfer(t)}
        end

      {:error, %Error{} = err} ->
        {:error, err}
    end
  end

  @impl true
  def list_jobs(_config, []), do: {:ok, %{}}

  def list_jobs(config, provider_job_ids) do
    requested = MapSet.new(provider_job_ids)

    case list_transfers(config) do
      {:ok, transfers} ->
        result =
          transfers
          |> Enum.filter(fn t -> to_string(t["id"]) in requested end)
          |> Map.new(fn t ->
            job = parse_transfer(t)
            {job.provider_id, job}
          end)

        {:ok, result}

      {:error, %Error{} = err} ->
        {:error, err}
    end
  end

  defp list_transfers(config) do
    case Req.get(base_url() <> "/transfer/list", headers: auth_headers(config)) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case wrap_pm(body, config) do
          {:ok, %{"transfers" => transfers}} ->
            {:ok, transfers}

          {:error, err} ->
            {:error, err}

          _ ->
            {:error,
             Error.parse_error("Unexpected PM transfer/list shape", %{
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
  def get_download_urls(config, %ProviderJob{raw_status: raw}) do
    cond do
      file_id = raw["file_id"] -> file_url(config, file_id)
      folder_id = raw["folder_id"] -> folder_urls(config, folder_id)
      true -> {:ok, []}
    end
  end

  defp file_url(config, file_id) do
    case Req.get(base_url() <> "/item/details",
           params: %{id: file_id},
           headers: auth_headers(config)
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case wrap_pm(body, config) do
          {:ok, %{"link" => url}} when is_binary(url) ->
            {:ok, [url]}

          {:error, err} ->
            {:error, err}

          _ ->
            {:error,
             Error.parse_error("Unexpected PM item/details shape", %{body: sanitize(body, config)})}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, build_error(status, body, config)}

      {:error, %Req.TransportError{} = err} ->
        {:error, Error.from_req_error(err)}
    end
  end

  defp folder_urls(config, folder_id) do
    case Req.get(base_url() <> "/folder/list",
           params: %{id: folder_id},
           headers: auth_headers(config)
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case wrap_pm(body, config) do
          {:ok, data} -> {:ok, walk_folder(data["content"] || [], config)}
          {:error, err} -> {:error, err}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, build_error(status, body, config)}

      {:error, %Req.TransportError{} = err} ->
        {:error, Error.from_req_error(err)}
    end
  end

  defp walk_folder(entries, config) do
    Enum.flat_map(entries, fn
      %{"type" => "file", "link" => url} when is_binary(url) ->
        [url]

      %{"type" => "folder", "id" => sub_id} ->
        case folder_urls(config, sub_id) do
          {:ok, urls} -> urls
          _ -> []
        end

      _ ->
        []
    end)
  end

  @impl true
  def delete_job(config, provider_job_id) do
    case Req.post(base_url() <> "/transfer/delete",
           form: [{"id", provider_job_id}],
           headers: auth_headers(config)
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case wrap_pm(body, config) do
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

  defp parse_transfer(%{} = t) do
    %ProviderJob{
      provider_id: to_string(t["id"]),
      state: map_status(t["status"]),
      progress: (t["progress"] || 0.0) * 100.0,
      name: t["name"],
      total_bytes: t["size"] || 0,
      files: [],
      hoster_links: [],
      raw_status: t
    }
  end

  defp map_status("waiting"), do: :queued
  defp map_status("queued"), do: :queued
  defp map_status("running"), do: :downloading
  defp map_status("seeding"), do: :ready
  defp map_status("finished"), do: :ready
  defp map_status("error"), do: :error
  defp map_status(_), do: :queued

  ## ── Envelope wrapper ────────────────────────────────────────────────

  defp wrap_pm(%{"status" => "success"} = body, _config), do: {:ok, body}

  defp wrap_pm(%{"status" => "error", "message" => msg} = body, config) do
    code = body["error_code"] || extract_code_from_message(msg)
    {:error, error_for_code(code, body, config)}
  end

  defp wrap_pm(other, config),
    do: {:error, Error.parse_error("Unexpected PM envelope", %{body: sanitize(other, config)})}

  defp extract_code_from_message("not_found"), do: "not_found"
  defp extract_code_from_message("rate_limit_reached"), do: "rate_limit_reached"
  defp extract_code_from_message(_), do: nil

  defp error_for_code(code, body, config) do
    sanitized = sanitize(body, config)

    case code do
      "authentication_failed" ->
        Error.authentication_failed("PM auth failed", %{body: sanitized})

      "permission_denied" ->
        Error.authentication_failed("PM permission denied", %{body: sanitized})

      "not_found" ->
        Error.not_found("PM resource not found", %{body: sanitized})

      "service_unsupported" ->
        Error.invalid_torrent("PM service unsupported", %{body: sanitized})

      "account_limit_reached" ->
        Error.api_error("PM account limit", %{reason: :slot_limit, body: sanitized})

      "service_limit_reached" ->
        Error.api_error("PM service limit", %{reason: :provider_unavailable, body: sanitized})

      "service_down" ->
        Error.api_error("PM service down", %{reason: :provider_unavailable, body: sanitized})

      "rate_limit_reached" ->
        Error.api_error("PM rate limited", %{reason: :rate_limited, body: sanitized})

      _ ->
        Error.api_error("PM error: #{inspect(code)}", %{body: sanitized})
    end
  end

  ## ── HTTP error mapping ──────────────────────────────────────────────

  defp build_error(429, _body, _config),
    do: Error.api_error("PM rate-limited", %{reason: :rate_limited})

  defp build_error(503, _body, _config), do: Error.network_error("PM upstream unavailable")

  defp build_error(status, body, config),
    do: Error.api_error("PM HTTP #{status}", %{body: sanitize(body, config)})

  defp sanitize(body, config), do: Shared.sanitize_error_body(body, config)
end
