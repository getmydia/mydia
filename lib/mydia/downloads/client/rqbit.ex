defmodule Mydia.Downloads.Client.Rqbit do
  @moduledoc """
  rqbit download client adapter.

  Implements the download client behaviour for [rqbit](https://github.com/ikatson/rqbit),
  a lightweight bittorrent client written in Rust that exposes a JSON HTTP API.
  Mydia talks to a user-run `rqbit server` instance; it does not embed or manage
  the rqbit process.

  ## Configuration

      config = %{
        type: :rqbit,
        host: "localhost",
        port: 3030,            # rqbit's default HTTP port
        username: "user",      # optional, HTTP basic auth
        password: "pass",      # optional, HTTP basic auth
        use_ssl: false,
        options: %{
          timeout: 30_000,
          connect_timeout: 5_000
        }
      }

  ## Identifiers

  rqbit assigns a numeric `id` that is **not stable across server restarts** (it is
  reassigned in load order). The 40-character hex `info_hash` is stable and is
  accepted in every `/torrents/{id}` path, so this adapter uses the info hash as the
  `client_id` returned from `add_torrent/3` and as `DownloadStatus.id`, and addresses
  all per-torrent endpoints by info hash.

  ## State mapping

  rqbit reports a small `state` enum plus a top-level `finished` boolean. There is no
  separate "seeding" state — a completed torrent that is still seeding reports
  `state: "live"` with `finished: true`. Because `Mydia.Jobs.DownloadMonitor` only
  triggers import once a download reaches `:seeding`/`:completed`, the
  `live + finished` case maps to `:seeding`:

    * `"error"` -> `:error`
    * `"initializing"` -> `:checking` (metadata/hash verification)
    * `"paused"` -> `:paused`
    * `"live"` with `finished: true` -> `:seeding`
    * `"live"` with `finished: false` -> `:downloading`
    * anything else -> `:unknown`

  ## Categories

  rqbit has no category/label concept. Like the Transmission adapter, this adapter
  ignores `opts[:category]`/`opts[:tags]` on add and treats `list_torrents` category
  and tag filters as no-ops. Final on-disk organization happens at the import step.

  ## Pause on add

  rqbit's HTTP API does not expose the `paused` add option as a query parameter, so
  when `opts[:paused]` is set the adapter adds the torrent and then issues a separate
  pause request. A failure to pause a freshly-added torrent is logged but not fatal.
  """

  @behaviour Mydia.Downloads.Client

  @impl true
  def supported_protocols, do: [:torrent]

  require Logger

  alias Mydia.Downloads.Client.{Error, HTTP}
  alias Mydia.Downloads.Structs.{ClientInfo, DownloadStatus}

  # rqbit reports speeds in mebibytes per second (MiB/s).
  @bytes_per_mib 1_048_576

  @impl true
  def test_connection(config) do
    req = HTTP.new_request(config)

    case HTTP.get(req, "/torrents") do
      {:ok, %{status: status}} when status in 200..299 ->
        {:ok, ClientInfo.new(version: "rqbit")}

      {:ok, response} ->
        {:error, api_error_from(response)}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def add_torrent(config, torrent, opts \\ []) do
    req = HTTP.new_request(config)
    {body, params} = build_add_request(torrent, opts)

    case HTTP.post(req, "/torrents", params: params, body: body) do
      {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
        case extract_info_hash(resp_body) do
          nil ->
            {:error,
             Error.parse_error("rqbit add response missing info_hash", %{body: resp_body})}

          info_hash ->
            maybe_pause_after_add(config, info_hash, opts)
            {:ok, info_hash}
        end

      {:ok, response} ->
        {:error, api_error_from(response)}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def get_status(config, client_id) do
    req = HTTP.new_request(config)

    with {:ok, details} <- fetch_details(req, client_id),
         {:ok, stats} <- fetch_stats(req, client_id) do
      {:ok, build_status(details, stats)}
    end
  end

  @impl true
  def list_torrents(config, opts \\ []) do
    req = HTTP.new_request(config)

    case HTTP.get(req, "/torrents", params: %{with_stats: true}) do
      {:ok, %{status: status, body: %{"torrents" => torrents}}} when status in 200..299 ->
        parsed =
          torrents
          |> Enum.map(fn torrent -> build_status(torrent, torrent["stats"] || %{}) end)
          |> apply_filters(opts)

        {:ok, parsed}

      {:ok, %{status: status}} when status in 200..299 ->
        {:ok, []}

      {:ok, response} ->
        {:error, api_error_from(response)}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def list_files(config, client_id) do
    # `resolve_torrent_files/2` already produces a genuine leaf enumeration
    # from the torrent details endpoint's `files` array (joining each entry's
    # `name`/`components` onto `output_folder` and skipping `included: false`
    # entries), so `get_status/2` is the single source of truth here. `files`
    # is nil when the client reported none yet, which the callback contract
    # represents as an empty list ("unknown"), never as "this torrent is empty".
    case get_status(config, client_id) do
      {:ok, %DownloadStatus{files: files}} when is_list(files) -> {:ok, files}
      {:ok, %DownloadStatus{}} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def remove_torrent(config, client_id, opts \\ []) do
    req = HTTP.new_request(config)
    action = if Keyword.get(opts, :delete_files, false), do: "delete", else: "forget"

    case HTTP.post(req, "/torrents/#{client_id}/#{action}", []) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, response} ->
        {:error, api_error_from(response)}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def pause_torrent(config, client_id) do
    control(config, client_id, "pause")
  end

  @impl true
  def resume_torrent(config, client_id) do
    control(config, client_id, "start")
  end

  ## Private Functions

  defp control(config, client_id, action) do
    req = HTTP.new_request(config)

    case HTTP.post(req, "/torrents/#{client_id}/#{action}", []) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, response} ->
        {:error, api_error_from(response)}

      {:error, _} = error ->
        error
    end
  end

  # Builds the {body, query_params} pair for POST /torrents.
  #
  # rqbit reads the raw request body as either a URL/magnet string or `.torrent`
  # bytes. `is_url` disambiguates explicitly; `output_folder` overrides the session
  # default when the pipeline supplies a save_path. Category/tags are intentionally
  # dropped (rqbit has no such concept).
  defp build_add_request({:magnet, magnet}, opts) do
    {magnet, add_params(opts, is_url: true)}
  end

  defp build_add_request({:url, url}, opts) do
    {url, add_params(opts, is_url: true)}
  end

  defp build_add_request({:file, contents}, opts) do
    {contents, add_params(opts, is_url: false)}
  end

  defp add_params(opts, is_url: is_url) do
    %{is_url: is_url}
    |> maybe_put(:output_folder, opts[:save_path])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_pause_after_add(config, info_hash, opts) do
    if Keyword.get(opts, :paused, false) do
      case pause_torrent(config, info_hash) do
        :ok ->
          :ok

        {:error, error} ->
          Logger.warning("Failed to pause rqbit torrent after add",
            info_hash: info_hash,
            error: inspect(error)
          )

          :ok
      end
    end
  end

  defp fetch_details(req, client_id) do
    case HTTP.get(req, "/torrents/#{client_id}") do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %{status: 404} = response} ->
        {:error, api_error_from(response)}

      {:ok, response} ->
        {:error, api_error_from(response)}

      {:error, _} = error ->
        error
    end
  end

  defp fetch_stats(req, client_id) do
    case HTTP.get(req, "/torrents/#{client_id}/stats/v1") do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, response} ->
        {:error, api_error_from(response)}

      {:error, _} = error ->
        error
    end
  end

  # Builds a DownloadStatus from a torrent details map and a stats map. Both the
  # list endpoint (stats embedded per item) and the single-status path (details +
  # stats/v1) converge here.
  #
  # `files` is always populated from the torrent's own file list when present.
  # rqbit frequently sets `output_folder` to a shared download directory for
  # single-file torrents; without an explicit file list MediaImport would
  # recurse that shared folder and import every neighboring torrent's files
  # into the wrong series library.
  defp build_status(details, stats) do
    finished = stats["finished"] == true
    total_bytes = stats["total_bytes"] || 0
    output_folder = details["output_folder"] || ""

    DownloadStatus.new(%{
      id: details["info_hash"],
      name: details["name"] || "",
      state: parse_state(stats),
      progress: progress(finished, stats["progress_bytes"], total_bytes),
      download_speed: speed_bytes(stats, "download_speed"),
      upload_speed: speed_bytes(stats, "upload_speed"),
      downloaded: stats["progress_bytes"] || 0,
      uploaded: stats["uploaded_bytes"] || 0,
      size: total_bytes,
      eta: parse_eta(stats),
      ratio: ratio(stats["uploaded_bytes"], total_bytes),
      save_path: output_folder,
      files: resolve_torrent_files(output_folder, details["files"]),
      added_at: nil,
      completed_at: nil
    })
  end

  # Resolve absolute paths for files belonging to this torrent.
  # Prefer `name` (path relative to output_folder); fall back to joining
  # `components`. Skip files marked `included: false`.
  defp resolve_torrent_files(_output_folder, files) when not is_list(files), do: nil

  defp resolve_torrent_files(output_folder, files) do
    paths =
      files
      |> Enum.filter(&file_included?/1)
      |> Enum.map(&absolute_torrent_path(output_folder, &1))
      |> Enum.reject(&(is_nil(&1) or &1 == ""))

    case paths do
      [] -> nil
      list -> list
    end
  end

  defp file_included?(%{"included" => false}), do: false
  defp file_included?(_), do: true

  defp absolute_torrent_path(output_folder, file) when is_map(file) do
    rel =
      cond do
        is_binary(file["name"]) and file["name"] != "" ->
          file["name"]

        is_list(file["components"]) and file["components"] != [] ->
          Path.join(file["components"])

        true ->
          nil
      end

    cond do
      is_nil(rel) ->
        nil

      output_folder == "" ->
        rel

      true ->
        Path.join(output_folder, rel)
    end
  end

  defp absolute_torrent_path(_output_folder, _), do: nil

  defp parse_state(%{"state" => "error"}), do: :error
  defp parse_state(%{"state" => "initializing"}), do: :checking
  defp parse_state(%{"state" => "paused"}), do: :paused
  defp parse_state(%{"state" => "live", "finished" => true}), do: :seeding
  defp parse_state(%{"state" => "live"}), do: :downloading
  defp parse_state(_), do: :unknown

  defp progress(true, _progress_bytes, _total), do: 100.0
  defp progress(false, _progress_bytes, total) when not is_integer(total) or total <= 0, do: 0.0

  defp progress(false, progress_bytes, total) do
    (progress_bytes || 0) / total * 100.0
  end

  # rqbit reports download_speed/upload_speed as %{"mbps" => float} in MiB/s under
  # the `live` sub-object, which is null when not actively transferring.
  defp speed_bytes(stats, key) do
    case get_in(stats, ["live", key, "mbps"]) do
      mbps when is_number(mbps) -> round(mbps * @bytes_per_mib)
      _ -> 0
    end
  end

  defp parse_eta(stats) do
    case get_in(stats, ["live", "time_remaining", "duration", "secs"]) do
      secs when is_integer(secs) and secs >= 0 -> secs
      _ -> nil
    end
  end

  defp ratio(uploaded, total) when is_integer(uploaded) and is_integer(total) and total > 0 do
    uploaded / total
  end

  defp ratio(_uploaded, _total), do: 0.0

  defp extract_info_hash(body) when is_map(body) do
    get_in(body, ["details", "info_hash"]) || body["info_hash"]
  end

  defp extract_info_hash(_), do: nil

  # rqbit error bodies are JSON: %{"error_kind" => ..., "human_readable" => ..., "status" => ...}.
  defp api_error_from(response) do
    body = response.body
    msg = human_readable(body) || "rqbit API error (HTTP #{response.status})"

    cond do
      error_kind(body) == "torrent_not_found" or response.status == 404 ->
        Error.not_found(msg)

      error_kind(body) == "unauthorized" or response.status == 401 ->
        Error.authentication_failed(msg)

      true ->
        Error.api_error(msg, %{status: response.status})
    end
  end

  defp error_kind(body) when is_map(body), do: body["error_kind"]
  defp error_kind(_), do: nil

  defp human_readable(body) when is_map(body), do: body["human_readable"]
  defp human_readable(_), do: nil

  # Category and tag filters are no-ops: rqbit has no such concept, and Mydia tracks
  # its own downloads by info hash. Mirrors the Transmission adapter.
  defp apply_filters(torrents, opts) do
    torrents
    |> filter_by_state(opts[:filter])
    |> filter_by_category(opts[:category])
    |> filter_by_tag(opts[:tag])
  end

  defp filter_by_state(torrents, nil), do: torrents
  defp filter_by_state(torrents, :all), do: torrents

  defp filter_by_state(torrents, filter) do
    Enum.filter(torrents, fn torrent ->
      case filter do
        :downloading -> torrent.state == :downloading
        :seeding -> torrent.state == :seeding
        :paused -> torrent.state == :paused
        :completed -> torrent.progress >= 100.0
        :active -> torrent.download_speed > 0 || torrent.upload_speed > 0
        :inactive -> torrent.download_speed == 0 && torrent.upload_speed == 0
        _ -> true
      end
    end)
  end

  defp filter_by_category(torrents, _category), do: torrents
  defp filter_by_tag(torrents, _tag), do: torrents
end
