defmodule Mydia.Downloads.Client.Sabnzbd do
  @moduledoc """
  SABnzbd download client adapter.

  Implements the download client behaviour for SABnzbd using its REST API.
  SABnzbd is a popular Usenet binary newsreader written in Python.

  ## API Documentation

  SABnzbd API: https://sabnzbd.org/wiki/advanced/api

  ## Authentication

  SABnzbd uses API key authentication passed as a query parameter in all requests.
  The API key can be found in SABnzbd's web interface under Config > General > API Key.

  ## Configuration

  The adapter expects the following configuration:

      config = %{
        type: :sabnzbd,
        host: "localhost",
        port: 8080,
        use_ssl: false,
        api_key: "your-api-key-here",
        url_base: nil,  # optional, e.g., "/sabnzbd"
        options: %{
          timeout: 30_000,
          connect_timeout: 5_000
        }
      }

  ## State Mapping

  SABnzbd states are mapped to our internal states:

    * `Downloading`, `Fetching` -> `:downloading`
    * `Paused` -> `:paused`
    * `Completed` -> `:completed`
    * `Failed`, `Extracting`, `Moving` -> `:error`
    * `Queued` -> `:downloading` (queued but counted as downloading)
    * `Verifying`, `Repairing` -> `:checking`

  ## API Response Format

  SABnzbd returns JSON responses. The main endpoints used:

    * `mode=version` - Get version info
    * `mode=addurl` - Add NZB from URL
    * `mode=queue` - Get queue status
    * `mode=history` - Get completed downloads
    * `mode=pause` - Pause a download
    * `mode=resume` - Resume a download
    * `mode=queue&name=delete` - Remove from queue
  """

  @behaviour Mydia.Downloads.Client

  alias Mydia.Downloads.Client.{Error, HTTP}
  alias Mydia.Downloads.Structs.{ClientInfo, TorrentStatus}
  require Logger

  @impl true
  def test_connection(config) do
    unless config[:api_key] do
      {:error, Error.invalid_config("API key is required for SABnzbd")}
    else
      do_test_connection(config)
    end
  end

  defp do_test_connection(config) do
    req = HTTP.new_request(config)

    params = [
      apikey: config.api_key,
      output: "json",
      mode: "version"
    ]

    api_path = build_api_path(config)

    case HTTP.get(req, api_path, params: params) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        version = get_in(body, ["version"]) || "unknown"
        {:ok, ClientInfo.new(version: version, api_version: "1.0")}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.api_error("Unexpected response status", %{status: status, body: body})}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def add_torrent(config, torrent, opts \\ []) do
    unless config[:api_key] do
      {:error, Error.invalid_config("API key is required for SABnzbd")}
    else
      do_add_nzb(config, torrent, opts)
    end
  end

  defp do_add_nzb(config, {:url, url}, opts) do
    req = HTTP.new_request(config)

    params =
      [
        apikey: config.api_key,
        output: "json",
        mode: "addurl",
        name: url
      ]
      |> add_optional_param(:cat, opts[:category])
      |> add_optional_param(:priority, map_priority(opts[:priority]))

    api_path = build_api_path(config)

    case HTTP.get(req, api_path, params: params) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        # SABnzbd returns {"status": true, "nzo_ids": ["SABnzbd_nzo_xxxxx"]}
        case get_in(body, ["nzo_ids"]) do
          [nzo_id | _] when is_binary(nzo_id) ->
            {:ok, nzo_id}

          _ ->
            # Check if there's an error in the response
            if get_in(body, ["status"]) == false do
              error_msg = get_in(body, ["error"]) || "Unknown error"
              {:error, Error.api_error("Failed to add NZB: #{error_msg}")}
            else
              {:error, Error.api_error("Invalid response from SABnzbd", %{body: body})}
            end
        end

      {:ok, %{status: status, body: body}} ->
        {:error, Error.api_error("Failed to add NZB", %{status: status, body: body})}

      {:error, error} ->
        {:error, error}
    end
  end

  defp do_add_nzb(config, {:file, file_contents}, opts) do
    req = HTTP.new_request(config)

    # For file uploads, we need to use multipart form data
    params =
      [
        apikey: config.api_key,
        output: "json",
        mode: "addfile"
      ]
      |> add_optional_param(:cat, opts[:category])
      |> add_optional_param(:priority, map_priority(opts[:priority]))

    api_path = build_api_path(config)

    # Create multipart form with the NZB file
    multipart_body = [
      {:file, file_contents, [name: "nzbfile", filename: "upload.nzb"]}
    ]

    case HTTP.post(req, api_path, params: params, form_multipart: multipart_body) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        case get_in(body, ["nzo_ids"]) do
          [nzo_id | _] when is_binary(nzo_id) ->
            {:ok, nzo_id}

          _ ->
            if get_in(body, ["status"]) == false do
              error_msg = get_in(body, ["error"]) || "Unknown error"
              {:error, Error.api_error("Failed to add NZB: #{error_msg}")}
            else
              {:error, Error.api_error("Invalid response from SABnzbd", %{body: body})}
            end
        end

      {:ok, %{status: status, body: body}} ->
        {:error, Error.api_error("Failed to add NZB", %{status: status, body: body})}

      {:error, error} ->
        {:error, error}
    end
  end

  defp do_add_nzb(_config, {:magnet, _magnet_link}, _opts) do
    {:error, Error.invalid_torrent("SABnzbd does not support magnet links (Usenet client)")}
  end

  @impl true
  def get_status(config, client_id) do
    with {:ok, queue_items} <- list_queue_items(config),
         {:ok, history_items} <- list_history_items(config) do
      # Search in queue first, then history
      case find_item_by_id(queue_items ++ history_items, client_id) do
        nil ->
          {:error, Error.not_found("Download not found")}

        item ->
          {:ok, parse_item_status(item)}
      end
    end
  end

  @impl true
  def list_torrents(config, opts \\ []) do
    filter = Keyword.get(opts, :filter, :all)

    with {:ok, queue_items} <- list_queue_items(config),
         {:ok, history_items} <- list_history_items(config) do
      all_items = queue_items ++ history_items

      filtered_items =
        case filter do
          :all ->
            all_items

          :downloading ->
            Enum.filter(all_items, &(&1["status"] in ["Downloading", "Fetching", "Queued"]))

          :paused ->
            Enum.filter(all_items, &(&1["status"] == "Paused"))

          :completed ->
            Enum.filter(all_items, &(&1["status"] == "Completed"))

          :active ->
            Enum.filter(
              all_items,
              &(&1["status"] in ["Downloading", "Fetching", "Verifying", "Repairing"])
            )

          _ ->
            all_items
        end

      torrents = Enum.map(filtered_items, &parse_item_status/1)
      {:ok, torrents}
    end
  end

  @impl true
  def remove_torrent(config, client_id, opts \\ []) do
    unless config[:api_key] do
      {:error, Error.invalid_config("API key is required for SABnzbd")}
    else
      do_remove(config, client_id, opts)
    end
  end

  defp do_remove(config, client_id, opts) do
    req = HTTP.new_request(config)
    delete_files = Keyword.get(opts, :delete_files, false)

    # First try to remove from queue
    params = [
      apikey: config.api_key,
      output: "json",
      mode: "queue",
      name: "delete",
      value: client_id,
      del_files: if(delete_files, do: "1", else: "0")
    ]

    api_path = build_api_path(config)

    case HTTP.get(req, api_path, params: params) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        if get_in(body, ["status"]) == true do
          :ok
        else
          # If not in queue, try removing from history
          remove_from_history(config, client_id, delete_files)
        end

      {:ok, %{status: status}} ->
        {:error, Error.api_error("Failed to remove download", %{status: status})}

      {:error, error} ->
        {:error, error}
    end
  end

  defp remove_from_history(config, client_id, delete_files) do
    req = HTTP.new_request(config)

    params = [
      apikey: config.api_key,
      output: "json",
      mode: "history",
      name: "delete",
      value: client_id,
      del_files: if(delete_files, do: "1", else: "0")
    ]

    api_path = build_api_path(config)

    case HTTP.get(req, api_path, params: params) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        if get_in(body, ["status"]) == true do
          :ok
        else
          {:error, Error.not_found("Download not found in queue or history")}
        end

      {:ok, %{status: status}} ->
        {:error, Error.api_error("Failed to remove from history", %{status: status})}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def pause_torrent(config, client_id) do
    unless config[:api_key] do
      {:error, Error.invalid_config("API key is required for SABnzbd")}
    else
      do_pause(config, client_id)
    end
  end

  defp do_pause(config, client_id) do
    req = HTTP.new_request(config)

    params = [
      apikey: config.api_key,
      output: "json",
      mode: "queue",
      name: "pause",
      value: client_id
    ]

    api_path = build_api_path(config)

    case HTTP.get(req, api_path, params: params) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        if get_in(body, ["status"]) == true do
          :ok
        else
          {:error, Error.api_error("Failed to pause download")}
        end

      {:ok, %{status: status}} ->
        {:error, Error.api_error("Failed to pause download", %{status: status})}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def resume_torrent(config, client_id) do
    unless config[:api_key] do
      {:error, Error.invalid_config("API key is required for SABnzbd")}
    else
      do_resume(config, client_id)
    end
  end

  defp do_resume(config, client_id) do
    req = HTTP.new_request(config)

    params = [
      apikey: config.api_key,
      output: "json",
      mode: "queue",
      name: "resume",
      value: client_id
    ]

    api_path = build_api_path(config)

    case HTTP.get(req, api_path, params: params) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        if get_in(body, ["status"]) == true do
          :ok
        else
          {:error, Error.api_error("Failed to resume download")}
        end

      {:ok, %{status: status}} ->
        {:error, Error.api_error("Failed to resume download", %{status: status})}

      {:error, error} ->
        {:error, error}
    end
  end

  ## Private Functions

  defp build_api_path(config) do
    base = config[:url_base] || ""
    "#{base}/api"
  end

  defp list_queue_items(config) do
    req = HTTP.new_request(config)

    params = [
      apikey: config.api_key,
      output: "json",
      mode: "queue"
    ]

    api_path = build_api_path(config)

    case HTTP.get(req, api_path, params: params) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        slots = get_in(body, ["queue", "slots"]) || []
        {:ok, slots}

      {:ok, %{status: status}} ->
        {:error, Error.api_error("Failed to fetch queue", %{status: status})}

      {:error, error} ->
        {:error, error}
    end
  end

  defp list_history_items(config) do
    req = HTTP.new_request(config)

    params = [
      apikey: config.api_key,
      output: "json",
      mode: "history",
      limit: "100"
    ]

    api_path = build_api_path(config)

    case HTTP.get(req, api_path, params: params) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        slots = get_in(body, ["history", "slots"]) || []
        {:ok, slots}

      {:ok, %{status: status}} ->
        {:error, Error.api_error("Failed to fetch history", %{status: status})}

      {:error, error} ->
        {:error, error}
    end
  end

  defp find_item_by_id(items, client_id) do
    Enum.find(items, fn item ->
      get_in(item, ["nzo_id"]) == client_id
    end)
  end

  defp parse_item_status(item) do
    nzo_id = get_in(item, ["nzo_id"]) || ""
    filename = get_in(item, ["filename"]) || ""
    status = get_in(item, ["status"]) || "Unknown"

    # SABnzbd returns sizes in different formats depending on queue/history
    # Queue: mb, mb_left as floats or strings
    # History: bytes as integer
    size_mb = parse_size(get_in(item, ["mb"]) || get_in(item, ["size"]))
    size_bytes = round(size_mb * 1024 * 1024)

    mb_left = parse_float(get_in(item, ["mbleft"])) || 0.0
    downloaded_mb = size_mb - mb_left
    downloaded_bytes = round(downloaded_mb * 1024 * 1024)

    # Calculate progress
    progress = if size_mb > 0, do: downloaded_mb / size_mb * 100, else: 0.0

    # Parse speeds and times
    download_speed_kb = parse_float(get_in(item, ["kbpersec"])) || 0.0
    download_speed_bytes = round(download_speed_kb * 1024)

    eta_text = get_in(item, ["timeleft"]) || "0:00:00"
    eta_seconds = parse_eta(eta_text)

    # Get storage path
    storage = get_in(item, ["storage"]) || get_in(item, ["path"]) || ""

    # Parse timestamps
    added_at = parse_timestamp(get_in(item, ["added"]))

    completed_at =
      if status == "Completed", do: parse_timestamp(get_in(item, ["completed"])), else: nil

    TorrentStatus.new(%{
      id: nzo_id,
      name: filename,
      state: parse_state(status),
      progress: progress,
      download_speed: download_speed_bytes,
      # Usenet doesn't upload
      upload_speed: 0,
      downloaded: downloaded_bytes,
      # Usenet doesn't upload
      uploaded: 0,
      size: size_bytes,
      eta: eta_seconds,
      # Usenet doesn't have ratios
      ratio: 0.0,
      save_path: storage,
      added_at: added_at,
      completed_at: completed_at
    })
  end

  defp parse_state(status) when is_binary(status) do
    case status do
      "Downloading" -> :downloading
      "Fetching" -> :downloading
      "Queued" -> :downloading
      "Paused" -> :paused
      "Completed" -> :completed
      "Failed" -> :error
      "Verifying" -> :checking
      "Repairing" -> :checking
      "Extracting" -> :checking
      "Moving" -> :checking
      _ -> :error
    end
  end

  defp parse_size(size) when is_float(size), do: size
  # bytes to MB
  defp parse_size(size) when is_integer(size), do: size / 1024 / 1024

  defp parse_size(size) when is_binary(size) do
    case Float.parse(size) do
      {float, _} -> float
      :error -> 0.0
    end
  end

  defp parse_size(_), do: 0.0

  defp parse_float(value) when is_float(value), do: value
  defp parse_float(value) when is_integer(value), do: value * 1.0

  defp parse_float(value) when is_binary(value) do
    case Float.parse(value) do
      {float, _} -> float
      :error -> 0.0
    end
  end

  defp parse_float(_), do: 0.0

  defp parse_eta(eta_text) when is_binary(eta_text) do
    # SABnzbd returns time in format "HH:MM:SS" or "0:00:00" for unknown
    case String.split(eta_text, ":") do
      [hours, minutes, seconds] ->
        h = String.to_integer(hours)
        m = String.to_integer(minutes)
        s = String.to_integer(seconds)
        h * 3600 + m * 60 + s

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp parse_eta(_), do: nil

  defp parse_timestamp(timestamp) when is_integer(timestamp) and timestamp > 0 do
    DateTime.from_unix!(timestamp)
  end

  defp parse_timestamp(_), do: nil

  defp add_optional_param(params, _key, nil), do: params

  defp add_optional_param(params, key, value) do
    params ++ [{key, value}]
  end

  defp map_priority(nil), do: nil
  defp map_priority(:low), do: "-1"
  defp map_priority(:normal), do: "0"
  defp map_priority(:high), do: "1"
  defp map_priority(_), do: nil
end
