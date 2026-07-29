defmodule Mydia.Downloads.Client.QBittorrent do
  @moduledoc """
  qBittorrent download client adapter.

  Implements the download client behaviour for qBittorrent using its Web API.
  qBittorrent uses cookie-based authentication and a REST-like API.

  ## API Documentation

  qBittorrent Web API: https://github.com/qbittorrent/qBittorrent/wiki/WebUI-API-(qBittorrent-4.1)

  ## qBittorrent 5.x compatibility

  qBittorrent 5.0 renamed the `pause`/`resume` endpoints to `stop`/`start` and
  introduced new state names (`stoppedDL`, `stoppedUP`, `moving`). This adapter
  tries the legacy endpoint first and falls back to the 5.x name on 404, and
  maps the new state names to their equivalent internal states.

  qBittorrent 5.2 changed authentication in two ways. `/api/v2/auth/login` now
  answers 204 with an empty body instead of 200 `Ok.`, so any 2xx is treated as
  success. The session cookie was renamed from `SID` to `QBT_SID_<port>`, where
  the port is the server's own WebUI port rather than the port we dial, so the
  cookie name is read from `Set-Cookie` and echoed back verbatim instead of
  being reconstructed. The old `SID` name is rejected outright by 5.2.

  ## Authentication modes

  Either an API key or a username and password is required.

  An `api_key` (qBittorrent 5.2+) is sent as `Authorization: Bearer <key>` on
  every request, with no login round trip and no session to expire. Keys are
  generated inside qBittorrent under Preferences, WebUI, API Key. qBittorrent
  holds exactly one key at a time and generating a new one immediately
  invalidates the previous one, so mydia never generates keys itself.

  Otherwise the adapter logs in with the username and password and maintains
  the session cookie, re-authenticating once when a request comes back 403.

  ## State Mapping

  qBittorrent states are mapped to our internal states:

    * `downloading`, `stalledDL`, `metaDL`, `forcedDL` -> `:downloading`
    * `uploading`, `stalledUP`, `forcedUP` -> `:seeding`
    * `pausedDL`, `pausedUP`, `stoppedDL`, `stoppedUP` -> `:paused`
    * `error`, `missingFiles` -> `:error`
    * `checkingDL`, `checkingUP`, `checkingResumeData`, `moving`, `allocating`,
      `queuedDL`, `queuedUP`, `unknown`, or anything we don't recognise -> `:checking`

  Unrecognised states are treated as `:checking` (transient) rather than `:error`
  because `DownloadMonitor` deletes rows for errored downloads, and we'd rather
  leave a download alone than lose it on a state name we haven't seen before.

  ## Priority

  qBittorrent's `/api/v2/torrents/add` endpoint does not accept a priority
  parameter directly — queue priority is managed via `topPrio` /
  `bottomPrio` / `increasePrio` / `decreasePrio` on the live torrent. As a
  result, this adapter's default behaviour is to **no-op** on priority: if
  `priority_profile` is empty (the default), no priority is sent to
  qBittorrent. When `priority_profile` supplies an override for the given
  atom, the value is logged so operators can wire up a follow-on integration,
  but is not yet applied. The 5-tier taxonomy is accepted so callers don't
  need to special-case torrent clients.
  """

  @behaviour Mydia.Downloads.Client

  @impl true
  def supported_protocols, do: [:torrent]

  require Logger

  alias Mydia.Downloads.Client.{Error, HTTP}
  alias Mydia.Downloads.Priority
  alias Mydia.Downloads.Client.Helpers
  alias Mydia.Downloads.Structs.{ClientInfo, DownloadStatus}
  alias Mydia.Downloads.TorrentHash

  # How many times to poll /torrents/info after add_torrent before declaring
  # the torrent was silently rejected by qBittorrent.
  @default_post_add_poll_attempts 5
  @post_add_poll_interval_ms 250

  @impl true
  def test_connection(config) do
    with_authenticated_session(config, fn req ->
      with {:ok, response} <- authed_request(req, :get, "/api/v2/app/version", []) do
        case response.status do
          200 ->
            {:ok, ClientInfo.new(version: to_string(response.body), api_version: "2.x")}

          _ ->
            {:error, Error.api_error("Unexpected response status", %{status: response.status})}
        end
      end
    end)
  end

  @impl true
  def add_torrent(config, torrent, opts \\ []) do
    _ = maybe_log_priority(config, opts[:priority])

    with {:ok, hash} <- extract_torrent_hash(torrent) do
      with_authenticated_session(config, fn req ->
        with {:ok, response} <- post_add_torrent(req, torrent, opts),
             :ok <- check_add_response(response),
             :ok <- verify_torrent_present(req, config, hash) do
          {:ok, hash}
        end
      end)
    end
  end

  # Priority is a no-op for qBittorrent's /torrents/add endpoint (see @moduledoc).
  # When `priority_profile` resolves the atom to a non-nil value, log it so
  # operators can confirm the look-up runs, then drop the value on the floor.
  # Empty profile -> nil -> silent (preserves pre-wave-2 behaviour).
  defp maybe_log_priority(_config, nil), do: :ok

  defp maybe_log_priority(config, atom)
       when atom in [:verylow, :low, :normal, :high, :veryhigh] do
    profile = Helpers.priority_profile(config)

    case Priority.resolve(atom, profile, nil) do
      nil ->
        :ok

      value ->
        Logger.debug(
          "qBittorrent priority requested but not applied (no add-endpoint support)",
          atom: atom,
          resolved_value: value
        )

        :ok
    end
  end

  defp maybe_log_priority(_config, _other), do: :ok

  @impl true
  def get_status(config, client_id) do
    with_authenticated_session(config, fn req ->
      with {:ok, response} <- get_info(req, hashes: client_id) do
        case response.body do
          [torrent | _] -> {:ok, parse_torrent_status(torrent)}
          [] -> {:error, Error.not_found("Torrent not found")}
          _other -> {:error, Error.parse_error("Unexpected response body")}
        end
      end
    end)
  end

  @impl true
  def list_torrents(config, opts \\ []) do
    params = build_list_params(opts)

    with_authenticated_session(config, fn req ->
      with {:ok, response} <- get_info(req, params) do
        if is_list(response.body) do
          {:ok, Enum.map(response.body, &parse_torrent_status/1)}
        else
          {:error, Error.parse_error("Unexpected response body")}
        end
      end
    end)
  end

  @impl true
  def remove_torrent(config, client_id, opts \\ []) do
    delete_files = Keyword.get(opts, :delete_files, false)
    body = %{hashes: client_id, deleteFiles: to_string(delete_files)}

    with_authenticated_session(config, fn req ->
      with {:ok, response} <- authed_request(req, :post, "/api/v2/torrents/delete", form: body) do
        case response.status do
          status when status in 200..299 -> :ok
          404 -> {:error, Error.not_found("Torrent not found")}
          status -> {:error, Error.api_error("Failed to remove torrent", %{status: status})}
        end
      end
    end)
  end

  @impl true
  def pause_torrent(config, client_id) do
    toggle_torrent(config, client_id, "/api/v2/torrents/pause", "/api/v2/torrents/stop")
  end

  @impl true
  def resume_torrent(config, client_id) do
    toggle_torrent(config, client_id, "/api/v2/torrents/resume", "/api/v2/torrents/start")
  end

  ## Private Functions

  # Authenticates, runs `fun` with the authenticated Req struct, and handles a
  # 403 from the inner call. In cookie mode this is a stale/expired session, so
  # we re-authenticate once and retry (matching the pattern used by the
  # Transmission adapter for 409 session-id retries). Under API-key auth a 403
  # means the key itself was rejected, so it is terminal: see
  # `retry_after_stale_session/2`.
  defp with_authenticated_session(config, fun) when is_function(fun, 1) do
    with {:ok, req} <- authenticate(config) do
      case fun.(req) do
        {:error, %Error{type: :stale_session}} ->
          retry_after_stale_session(config, fun)

        other ->
          other
      end
    end
  end

  # API-key auth has no session to refresh: a 403 means the key was rejected.
  # Re-running `fun` would also resend mutating requests such as
  # POST /torrents/add, so fail fast rather than retrying.
  defp retry_after_stale_session(config, fun) do
    if api_key?(config) do
      {:error,
       Error.authentication_failed("qBittorrent rejected the API key", %{
         hint: "Regenerate the key in qBittorrent under Preferences, WebUI, API Key"
       })}
    else
      with {:ok, fresh_req} <- authenticate(config) do
        case fun.(fresh_req) do
          # Never leak the internal marker: it is meaningless to an operator.
          {:error, %Error{type: :stale_session}} ->
            {:error, Error.authentication_failed("qBittorrent session could not be established")}

          other ->
            other
        end
      end
    end
  end

  defp api_key?(config), do: is_binary(config[:api_key]) and config[:api_key] != ""

  # Marker error indicating the caller should re-authenticate and retry.
  defp stale_session, do: Error.new(:stale_session, "Session expired")

  # An API key (qBittorrent 5.2+, WebAPI 2.14.1+) authenticates every request
  # directly, so there is no login round trip and no session to maintain.
  # put_header replaces, so this Bearer header wins over the Basic header that
  # HTTP.new_request/1 sets when credentials are also present.
  defp authenticate(%{api_key: key} = config) when is_binary(key) and key != "" do
    {:ok,
     config
     |> HTTP.new_request()
     |> Req.Request.put_header("authorization", "Bearer " <> key)}
  end

  defp authenticate(config) do
    if config[:username] && config[:password] do
      do_authenticate(config)
    else
      {:error,
       Error.invalid_config(
         "qBittorrent requires either an API key (5.2+) or a username and password"
       )}
    end
  end

  defp do_authenticate(config) do
    req = HTTP.new_request(config)
    login_body = %{username: config.username, password: config.password}

    case HTTP.post(req, "/api/v2/auth/login", form: login_body) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        if login_rejected_body?(response.body) do
          {:error, Error.authentication_failed("Invalid username or password")}
        else
          case extract_session_cookie(response) do
            {:ok, cookie} ->
              {:ok, Req.Request.put_header(req, "cookie", cookie)}

            :error ->
              {:error,
               Error.authentication_failed("Failed to extract session cookie", %{
                 hint:
                   "qBittorrent returned no recognisable session cookie " <>
                     "(expected SID or QBT_SID_<port>)",
                 cookies_seen: observed_cookie_names(response)
               })}
          end
        end

      {:ok, %{status: 401}} ->
        {:error, Error.authentication_failed("Invalid username or password")}

      {:ok, %{status: 403}} ->
        {:error,
         Error.authentication_failed("Invalid username or password", %{
           hint: "User's IP may be banned for too many failed login attempts"
         })}

      {:ok, response} ->
        {:error,
         Error.authentication_failed("Login failed", %{
           status: response.status,
           body: response.body
         })}

      {:error, error} ->
        {:error, error}
    end
  end

  # qBittorrent <= 5.1 answers a wrong-password login with HTTP 200 and body
  # "Fails." instead of an error status, so a 2xx alone doesn't mean success.
  # Checked before cookie extraction so this doesn't get misreported as a
  # missing/unrecognised session cookie.
  defp login_rejected_body?(body) when is_binary(body), do: String.trim(body) == "Fails."
  defp login_rejected_body?(_body), do: false

  # Session cookie under any qBittorrent naming scheme:
  #   <= 5.1  ->  SID=<value>
  #   >= 5.2  ->  QBT_SID_<webui_port>=<value>
  #
  # The port suffix is qBittorrent's OWN listening port, not the port we dial:
  # a 5.2 server listening on 8282 still issues QBT_SID_8282 when reached
  # through a proxy on another port. So the name cannot be derived from config
  # and must be read off Set-Cookie, then echoed back verbatim.
  #
  # Anchoring on (?:^|[\s;]) keeps unrelated cookies out: qBittorrent sometimes
  # emits a _csrf cookie alongside the session one, and a name like MYSID= must
  # not match either.
  @session_cookie ~r/(?:^|[\s;])((?:QBT_)?SID(?:_\d+)?=[^;]+)/

  defp extract_session_cookie(response) do
    response
    |> Req.Response.get_header("set-cookie")
    |> Enum.find_value(:error, fn cookie ->
      case Regex.run(@session_cookie, cookie) do
        [_, pair] -> {:ok, pair}
        _ -> nil
      end
    end)
  end

  # Names only, never values: this lands in logs, and the value is a live
  # session token.
  defp observed_cookie_names(response) do
    response
    |> Req.Response.get_header("set-cookie")
    |> Enum.map(fn cookie ->
      cookie |> String.split("=", parts: 2) |> hd() |> String.trim()
    end)
  end

  # Wrap an HTTP call so that a 403 (expired/invalid session) surfaces as a
  # marker error the outer `with_authenticated_session` can catch and retry
  # with a fresh login. Without this, sessions that expire after the qBittorrent
  # server's SessionTimeout cause every subsequent call to fail.
  defp authed_request(req, method, path, opts) do
    case do_request(req, method, path, opts) do
      {:ok, %{status: 403}} -> {:error, stale_session()}
      other -> other
    end
  end

  defp do_request(req, :get, path, opts), do: HTTP.get(req, path, opts)
  defp do_request(req, :post, path, opts), do: HTTP.post(req, path, opts)

  # Build POST body for add_torrent according to input type.
  defp post_add_torrent(req, {:magnet, magnet_link}, opts) do
    body =
      %{urls: magnet_link}
      |> put_optional(:category, opts[:category])
      |> put_optional(:tags, opts[:tags], &Enum.join(&1, ","))
      |> put_optional(:savepath, opts[:save_path])
      |> put_optional_bool(:paused, opts[:paused])

    authed_request(req, :post, "/api/v2/torrents/add", form: body)
  end

  defp post_add_torrent(req, {:url, url}, opts) do
    body =
      %{urls: url}
      |> put_optional(:category, opts[:category])
      |> put_optional(:tags, opts[:tags], &Enum.join(&1, ","))
      |> put_optional(:savepath, opts[:save_path])
      |> put_optional_bool(:paused, opts[:paused])

    authed_request(req, :post, "/api/v2/torrents/add", form: body)
  end

  defp post_add_torrent(req, {:file, file_contents}, opts) do
    # qBittorrent's /torrents/add expects multipart/form-data when uploading a
    # .torrent file. Passing the raw binary as a URL-encoded form silently
    # corrupts the body and the torrent is dropped without any error response.
    filename = opts[:title] |> sanitize_filename()

    fields =
      [
        torrents: {file_contents, filename: filename, content_type: "application/x-bittorrent"}
      ]
      |> put_optional_kv(:category, opts[:category])
      |> put_optional_kv(:tags, opts[:tags], &Enum.join(&1, ","))
      |> put_optional_kv(:savepath, opts[:save_path])
      |> put_optional_kv(:paused, opts[:paused], &to_string/1)

    authed_request(req, :post, "/api/v2/torrents/add", form_multipart: fields)
  end

  defp check_add_response(%{status: status}) when status in 200..299, do: :ok

  defp check_add_response(%{status: status, body: body}) do
    {:error, Error.api_error("Failed to add torrent", %{status: status, body: body})}
  end

  # After "Ok." we don't know whether qBittorrent actually accepted the torrent
  # (it returns "Ok." even when it silently drops bad input). Poll info?hashes=<h>
  # so the caller knows whether the torrent landed.
  defp verify_torrent_present(req, config, hash) do
    attempts =
      get_in(config, [:options, :post_add_poll_attempts]) ||
        @default_post_add_poll_attempts

    interval =
      get_in(config, [:options, :post_add_poll_interval_ms]) || @post_add_poll_interval_ms

    do_verify_torrent_present(req, hash, attempts, interval)
  end

  defp do_verify_torrent_present(_req, hash, 0, _interval) do
    {:error,
     Error.api_error(
       "Torrent not present in qBittorrent after add (may have been silently rejected)",
       %{hash: hash}
     )}
  end

  defp do_verify_torrent_present(req, hash, attempts_left, interval) do
    case get_info(req, hashes: hash) do
      {:ok, %{body: [_ | _]}} ->
        :ok

      _other ->
        if attempts_left > 1, do: Process.sleep(interval)
        do_verify_torrent_present(req, hash, attempts_left - 1, interval)
    end
  end

  defp get_info(req, params) do
    authed_request(req, :get, "/api/v2/torrents/info", params: params)
  end

  # Hit the legacy endpoint first, fall back to qBittorrent 5.x's renamed
  # endpoint if the server reports 404. Old clients respond 200 on both paths
  # via backwards-compat aliases, but on a fresh 5.x install the legacy path
  # returns 404 and we'd otherwise fail.
  defp toggle_torrent(config, client_id, primary_path, fallback_path) do
    body = %{hashes: client_id}

    with_authenticated_session(config, fn req ->
      case authed_request(req, :post, primary_path, form: body) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: 404}} ->
          case authed_request(req, :post, fallback_path, form: body) do
            {:ok, %{status: status}} when status in 200..299 -> :ok
            {:ok, resp} -> toggle_error(resp)
            {:error, _} = err -> err
          end

        {:ok, resp} ->
          toggle_error(resp)

        {:error, _} = err ->
          err
      end
    end)
  end

  defp toggle_error(%{status: status}) do
    {:error, Error.api_error("Failed to toggle torrent", %{status: status})}
  end

  defp build_list_params(opts) do
    []
    |> append_param(:filter, list_filter(opts[:filter]))
    |> append_param(:category, opts[:category])
    |> append_param(:tag, opts[:tag])
    |> append_param(:hashes, opts[:hashes])
  end

  defp list_filter(nil), do: nil
  defp list_filter(:all), do: nil
  defp list_filter(:downloading), do: "downloading"
  defp list_filter(:seeding), do: "seeding"
  defp list_filter(:completed), do: "completed"
  defp list_filter(:paused), do: "paused"
  defp list_filter(:active), do: "active"
  defp list_filter(:inactive), do: "inactive"
  defp list_filter(_), do: nil

  defp append_param(params, _key, nil), do: params
  defp append_param(params, key, value), do: [{key, value} | params]

  defp put_optional(body, _key, nil), do: body
  defp put_optional(body, key, value), do: Map.put(body, key, value)

  defp put_optional(body, _key, nil, _transform), do: body

  defp put_optional(body, key, value, transform) when is_function(transform, 1) do
    Map.put(body, key, transform.(value))
  end

  defp put_optional_bool(body, _key, nil), do: body
  defp put_optional_bool(body, key, value), do: Map.put(body, key, to_string(value))

  defp put_optional_kv(list, _key, nil), do: list
  defp put_optional_kv(list, key, value), do: list ++ [{key, value}]

  defp put_optional_kv(list, _key, nil, _transform), do: list
  defp put_optional_kv(list, key, value, transform), do: list ++ [{key, transform.(value)}]

  defp sanitize_filename(nil), do: "file.torrent"

  defp sanitize_filename(title) when is_binary(title) do
    base =
      title
      |> String.replace(~r/[^A-Za-z0-9._\- ]/, "_")
      |> String.slice(0, 200)

    if base == "", do: "file.torrent", else: base <> ".torrent"
  end

  defp sanitize_filename(_), do: "file.torrent"

  defp extract_torrent_hash(torrent_input) do
    # qBittorrent indexes torrents by lowercase hash.
    TorrentHash.extract(torrent_input, case: :lower)
  end

  defp parse_torrent_status(torrent) do
    save_path = torrent["save_path"] || ""

    DownloadStatus.new(%{
      id: torrent["hash"],
      name: torrent["name"],
      state: parse_state(torrent["state"]),
      progress: (torrent["progress"] || 0) * 100,
      download_speed: torrent["dlspeed"] || 0,
      upload_speed: torrent["upspeed"] || 0,
      downloaded: torrent["downloaded"] || 0,
      uploaded: torrent["uploaded"] || 0,
      size: torrent["size"] || 0,
      eta: parse_eta(torrent["eta"]),
      ratio: torrent["ratio"] || 0.0,
      save_path: save_path,
      files: content_files(save_path, torrent["content_path"]),
      added_at: Helpers.parse_timestamp_unix(torrent["added_on"]),
      completed_at: Helpers.parse_timestamp_unix(torrent["completion_on"])
    })
  end

  # `save_path` is the *containing* directory, so a single-file torrent reports
  # the shared download root verbatim — and MediaImport's fallback recursively
  # lists whatever it is handed. On a busy client that imports every
  # neighbouring release into this download's library folder.
  #
  # `content_path` (Web API >= 2.6.1, already returned by /torrents/info, so
  # this costs no extra request) points at the torrent's own data: the file
  # itself for a single-file torrent, the torrent's root folder for a
  # multi-file one. Either scopes the import correctly. Servers old enough to
  # omit it — and multi-file torrents added with subfolder creation disabled,
  # where content_path *is* save_path — fall back to the previous behaviour.
  defp content_files(save_path, content_path)
       when is_binary(content_path) and content_path != "" do
    if Path.expand(content_path) == Path.expand(save_path) do
      nil
    else
      [content_path]
    end
  end

  defp content_files(_save_path, _content_path), do: nil

  # State mappings. Unknown / unrecognised states deliberately fall through to
  # :checking (transient) rather than :error, because DownloadMonitor deletes
  # records whose status is "failed" — a misclassification here means the user
  # loses the download row.
  defp parse_state("downloading"), do: :downloading
  defp parse_state("stalledDL"), do: :downloading
  defp parse_state("metaDL"), do: :downloading
  defp parse_state("forcedDL"), do: :downloading
  defp parse_state("queuedDL"), do: :downloading
  defp parse_state("allocating"), do: :downloading
  defp parse_state("uploading"), do: :seeding
  defp parse_state("stalledUP"), do: :seeding
  defp parse_state("forcedUP"), do: :seeding
  defp parse_state("queuedUP"), do: :seeding
  defp parse_state("pausedDL"), do: :paused
  defp parse_state("pausedUP"), do: :paused
  defp parse_state("stoppedDL"), do: :paused
  defp parse_state("stoppedUP"), do: :paused
  defp parse_state("checkingDL"), do: :checking
  defp parse_state("checkingUP"), do: :checking
  defp parse_state("checkingResumeData"), do: :checking
  defp parse_state("moving"), do: :checking
  defp parse_state("error"), do: :error
  defp parse_state("missingFiles"), do: :error
  defp parse_state(_other), do: :checking

  defp parse_eta(eta) when is_integer(eta) and eta > 0, do: eta
  defp parse_eta(_), do: nil
end
