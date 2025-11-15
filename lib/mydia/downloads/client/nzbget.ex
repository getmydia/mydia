defmodule Mydia.Downloads.Client.Nzbget do
  @moduledoc """
  NZBGet download client adapter.

  Implements the download client behaviour for NZBGet using its JSON-RPC API.
  NZBGet is a lightweight, high-performance Usenet binary downloader written in C++.

  ## API Documentation

  NZBGet API: https://nzbget.net/api

  ## Authentication

  NZBGet uses HTTP Basic Authentication. The username and password are passed
  in the request headers for all API calls.

  ## Configuration

  The adapter expects the following configuration:

      config = %{
        type: :nzbget,
        host: "localhost",
        port: 6789,
        use_ssl: false,
        username: "nzbget",
        password: "tegbzn6789",
        url_base: nil,  # optional, e.g., "/nzbget"
        options: %{
          timeout: 30_000,
          connect_timeout: 5_000
        }
      }

  ## State Mapping

  NZBGet states are mapped to our internal states:

    * `DOWNLOADING`, `FETCHING` -> `:downloading`
    * `PAUSED` -> `:paused`
    * `SUCCESS`, `DELETED` (with completion) -> `:completed`
    * `FAILURE`, `WARNING` -> `:error`
    * `QUEUED` -> `:downloading` (queued but counted as downloading)
    * `PP_QUEUED`, `LOADING_PARS`, `VERIFYING`, `REPAIRING`, `UNPACKING`, `MOVING` -> `:checking`

  ## JSON-RPC Protocol

  NZBGet uses JSON-RPC 2.0. All requests are POST with JSON body:

      {
        "jsonrpc": "2.0",
        "method": "version",
        "params": [],
        "id": 1
      }

  Response format:

      {
        "jsonrpc": "2.0",
        "result": "21.0",
        "id": 1
      }
  """

  @behaviour Mydia.Downloads.Client

  alias Mydia.Downloads.Client.{Error, HTTP}
  alias Mydia.Downloads.Structs.{ClientInfo, TorrentStatus}
  require Logger

  @impl true
  def test_connection(config) do
    unless config[:username] && config[:password] do
      {:error, Error.invalid_config("Username and password are required for NZBGet")}
    else
      do_test_connection(config)
    end
  end

  defp do_test_connection(config) do
    case rpc_call(config, "version", []) do
      {:ok, version} when is_binary(version) ->
        {:ok, ClientInfo.new(version: version, api_version: "JSON-RPC 2.0")}

      {:ok, result} ->
        {:error, Error.api_error("Unexpected version response", %{result: result})}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def add_torrent(config, torrent, opts \\ []) do
    unless config[:username] && config[:password] do
      {:error, Error.invalid_config("Username and password are required for NZBGet")}
    else
      do_add_nzb(config, torrent, opts)
    end
  end

  defp do_add_nzb(config, {:url, url}, opts) do
    # NZBGet's append method parameters: [NZBFilename, Content, Category, Priority, AddToTop, AddPaused, DupeKey, DupeScore, DupeMode]
    # For URL-based addition, we use the URL as both filename and content (NZBGet will fetch it)
    nzb_filename = extract_filename_from_url(url)
    category = Keyword.get(opts, :category, "")
    priority = map_priority(Keyword.get(opts, :priority))
    add_paused = Keyword.get(opts, :paused, false)

    # Content should be empty string for URL addition, NZBGet will fetch it
    params = [
      nzb_filename,
      # Empty content means NZBGet should treat NZBFilename as URL
      "",
      category,
      priority,
      # AddToTop
      false,
      add_paused,
      # DupeKey
      "",
      # DupeScore
      0,
      # DupeMode
      "SCORE"
    ]

    # Actually, for URLs we should use 'append' with URL in the content field encoded in base64
    # Let's use a different approach: download the NZB and send as file
    case fetch_nzb_from_url(url) do
      {:ok, nzb_content} ->
        do_add_nzb(config, {:file, nzb_content}, opts)

      {:error, _} = error ->
        error
    end
  end

  defp do_add_nzb(config, {:file, file_contents}, opts) do
    # For file uploads, we need to base64 encode the content
    # Use the title from opts if provided, otherwise fall back to "upload.nzb"
    nzb_filename =
      case Keyword.get(opts, :title) do
        nil -> "upload.nzb"
        title -> "#{title}.nzb"
      end

    nzb_content_base64 = Base.encode64(file_contents)
    category = Keyword.get(opts, :category, "")
    priority = map_priority(Keyword.get(opts, :priority))
    add_paused = Keyword.get(opts, :paused, false)

    params = [
      nzb_filename,
      nzb_content_base64,
      category,
      priority,
      # AddToTop
      false,
      add_paused,
      # DupeKey
      "",
      # DupeScore
      0,
      # DupeMode
      "SCORE"
    ]

    case rpc_call(config, "append", params) do
      {:ok, nzb_id} when is_integer(nzb_id) ->
        {:ok, Integer.to_string(nzb_id)}

      {:ok, result} ->
        {:error, Error.api_error("Failed to add NZB", %{result: result})}

      {:error, error} ->
        {:error, error}
    end
  end

  defp do_add_nzb(_config, {:magnet, _magnet_link}, _opts) do
    {:error, Error.invalid_torrent("NZBGet does not support magnet links (Usenet client)")}
  end

  @impl true
  def get_status(config, client_id) do
    # Convert string ID to integer for NZBGet
    nzb_id = String.to_integer(client_id)

    with {:ok, groups} <- list_groups(config),
         {:ok, history} <- list_history(config) do
      # Search in active groups first, then history
      all_items = groups ++ history

      case find_item_by_id(all_items, nzb_id) do
        nil ->
          {:error, Error.not_found("Download not found")}

        item ->
          {:ok, parse_item_status(item)}
      end
    end
  rescue
    ArgumentError ->
      {:error, Error.invalid_torrent("Invalid NZB ID format")}
  end

  @impl true
  def list_torrents(config, opts \\ []) do
    filter = Keyword.get(opts, :filter, :all)

    with {:ok, groups} <- list_groups(config),
         {:ok, history} <- list_history(config) do
      all_items = groups ++ history

      filtered_items =
        case filter do
          :all ->
            all_items

          :downloading ->
            Enum.filter(all_items, fn item ->
              status = get_in(item, ["Status"]) || ""
              status in ["DOWNLOADING", "FETCHING", "QUEUED"]
            end)

          :paused ->
            Enum.filter(all_items, fn item ->
              get_in(item, ["Status"]) == "PAUSED"
            end)

          :completed ->
            Enum.filter(all_items, fn item ->
              status = get_in(item, ["Status"]) || ""

              status in ["SUCCESS", "DELETED"] &&
                get_in(item, ["TotalArticles"]) == get_in(item, ["SuccessArticles"])
            end)

          :active ->
            Enum.filter(all_items, fn item ->
              status = get_in(item, ["Status"]) || ""
              status in ["DOWNLOADING", "FETCHING", "VERIFYING", "REPAIRING", "UNPACKING"]
            end)

          _ ->
            all_items
        end

      torrents = Enum.map(filtered_items, &parse_item_status/1)
      {:ok, torrents}
    end
  end

  @impl true
  def remove_torrent(config, client_id, opts \\ []) do
    unless config[:username] && config[:password] do
      {:error, Error.invalid_config("Username and password are required for NZBGet")}
    else
      do_remove(config, client_id, opts)
    end
  end

  defp do_remove(config, client_id, opts) do
    nzb_id = String.to_integer(client_id)
    delete_files = Keyword.get(opts, :delete_files, false)

    # First try to remove from queue using GroupDelete
    case rpc_call(config, "editqueue", ["GroupDelete", 0, "", [nzb_id]]) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        # Not in queue, try removing from history
        remove_from_history(config, nzb_id, delete_files)

      {:error, error} ->
        {:error, error}
    end
  rescue
    ArgumentError ->
      {:error, Error.invalid_torrent("Invalid NZB ID format")}
  end

  defp remove_from_history(config, nzb_id, delete_files) do
    # HistoryDelete parameters: [NZBID, FinalDelete (deletes files)]
    case rpc_call(config, "history", ["delete", 0, "", [nzb_id]]) do
      {:ok, true} ->
        if delete_files do
          # Also delete files from disk using HistoryFinalDelete
          rpc_call(config, "history", ["finaldelete", 0, "", [nzb_id]])
        end

        :ok

      {:ok, false} ->
        {:error, Error.not_found("Download not found in queue or history")}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def pause_torrent(config, client_id) do
    unless config[:username] && config[:password] do
      {:error, Error.invalid_config("Username and password are required for NZBGet")}
    else
      do_pause(config, client_id)
    end
  end

  defp do_pause(config, client_id) do
    nzb_id = String.to_integer(client_id)

    # Use editqueue with GroupPause command
    case rpc_call(config, "editqueue", ["GroupPause", 0, "", [nzb_id]]) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        {:error, Error.api_error("Failed to pause download (not in queue)")}

      {:error, error} ->
        {:error, error}
    end
  rescue
    ArgumentError ->
      {:error, Error.invalid_torrent("Invalid NZB ID format")}
  end

  @impl true
  def resume_torrent(config, client_id) do
    unless config[:username] && config[:password] do
      {:error, Error.invalid_config("Username and password are required for NZBGet")}
    else
      do_resume(config, client_id)
    end
  end

  defp do_resume(config, client_id) do
    nzb_id = String.to_integer(client_id)

    # Use editqueue with GroupResume command
    case rpc_call(config, "editqueue", ["GroupResume", 0, "", [nzb_id]]) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        {:error, Error.api_error("Failed to resume download (not in queue)")}

      {:error, error} ->
        {:error, error}
    end
  rescue
    ArgumentError ->
      {:error, Error.invalid_torrent("Invalid NZB ID format")}
  end

  ## Private Functions - RPC Communication

  defp rpc_call(config, method, params) do
    req = HTTP.new_request(config)
    rpc_path = build_rpc_path(config)

    request_body = %{
      jsonrpc: "2.0",
      method: method,
      params: params,
      id: :rand.uniform(1_000_000)
    }

    case HTTP.post(req, rpc_path, json: request_body) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        case body do
          %{"result" => result} ->
            {:ok, result}

          %{"error" => error} ->
            error_message = get_in(error, ["message"]) || "Unknown RPC error"
            {:error, Error.api_error("RPC error: #{error_message}", %{error: error})}

          _ ->
            {:error, Error.parse_error("Invalid JSON-RPC response", %{body: body})}
        end

      {:ok, %{status: 401}} ->
        {:error, Error.authentication_failed("Invalid username or password")}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.api_error("Unexpected response status", %{status: status, body: body})}

      {:error, error} ->
        {:error, error}
    end
  end

  defp build_rpc_path(config) do
    base = config[:url_base] || ""
    "#{base}/jsonrpc"
  end

  defp list_groups(config) do
    case rpc_call(config, "listgroups", []) do
      {:ok, groups} when is_list(groups) ->
        {:ok, groups}

      {:ok, result} ->
        {:error, Error.api_error("Invalid listgroups response", %{result: result})}

      {:error, error} ->
        {:error, error}
    end
  end

  defp list_history(config) do
    # History parameters: [Hidden]
    case rpc_call(config, "history", [false]) do
      {:ok, history} when is_list(history) ->
        {:ok, history}

      {:ok, result} ->
        {:error, Error.api_error("Invalid history response", %{result: result})}

      {:error, error} ->
        {:error, error}
    end
  end

  defp find_item_by_id(items, nzb_id) do
    Enum.find(items, fn item ->
      # In groups, it's "NZBID", in history it might be "ID" or "NZBID"
      item_id = get_in(item, ["NZBID"]) || get_in(item, ["ID"])
      item_id == nzb_id
    end)
  end

  defp parse_item_status(item) do
    nzb_id = get_in(item, ["NZBID"]) || get_in(item, ["ID"]) || 0
    nzb_name = get_in(item, ["NZBName"]) || get_in(item, ["Name"]) || ""
    status = get_in(item, ["Status"]) || "UNKNOWN"

    # Sizes in bytes
    file_size_mb = (get_in(item, ["FileSizeMB"]) || 0) * 1024 * 1024
    remaining_size_mb = (get_in(item, ["RemainingSizeMB"]) || 0) * 1024 * 1024
    downloaded_size_mb = file_size_mb - remaining_size_mb

    # Calculate progress
    progress = if file_size_mb > 0, do: downloaded_size_mb / file_size_mb * 100, else: 0.0

    # Download speed (bytes per second)
    download_speed = get_in(item, ["DownloadRate"]) || 0

    # ETA is not directly provided, calculate from remaining size and speed
    eta_seconds = if download_speed > 0, do: div(remaining_size_mb, download_speed), else: nil

    # Get destination path
    dest_dir = get_in(item, ["DestDir"]) || ""

    # Parse timestamps (NZBGet uses Unix timestamps)
    min_time = get_in(item, ["MinPostTime"]) || 0
    added_at = if min_time > 0, do: DateTime.from_unix!(min_time), else: nil

    # For history items, use the completion time
    completed_time = get_in(item, ["HistoryTime"]) || 0

    completed_at =
      if status in ["SUCCESS", "DELETED"] && completed_time > 0 do
        DateTime.from_unix!(completed_time)
      else
        nil
      end

    TorrentStatus.new(%{
      id: Integer.to_string(nzb_id),
      name: nzb_name,
      state: parse_state(status),
      progress: progress,
      download_speed: download_speed,
      # Usenet doesn't upload
      upload_speed: 0,
      downloaded: round(downloaded_size_mb),
      # Usenet doesn't upload
      uploaded: 0,
      size: round(file_size_mb),
      eta: eta_seconds,
      # Usenet doesn't have ratios
      ratio: 0.0,
      save_path: dest_dir,
      added_at: added_at,
      completed_at: completed_at
    })
  end

  defp parse_state(status) when is_binary(status) do
    case status do
      "DOWNLOADING" -> :downloading
      "FETCHING" -> :downloading
      "QUEUED" -> :downloading
      "PAUSED" -> :paused
      "SUCCESS" -> :completed
      "DELETED" -> :completed
      "FAILURE" -> :error
      "WARNING" -> :error
      "PP_QUEUED" -> :checking
      "LOADING_PARS" -> :checking
      "VERIFYING" -> :checking
      "REPAIRING" -> :checking
      "UNPACKING" -> :checking
      "MOVING" -> :checking
      "EXECUTING_SCRIPT" -> :checking
      _ -> :error
    end
  end

  defp extract_filename_from_url(url) do
    # Try to extract filename from URL
    case URI.parse(url) do
      %URI{path: path} when is_binary(path) ->
        path
        |> String.split("/")
        |> List.last()
        |> case do
          nil -> "download.nzb"
          "" -> "download.nzb"
          filename -> filename
        end

      _ ->
        "download.nzb"
    end
  end

  defp fetch_nzb_from_url(url) do
    Logger.debug("Fetching NZB from URL: #{url}")

    # Configure Req with reasonable timeouts and no retries
    # to avoid test timeouts when connecting to unreachable hosts
    case Req.get(url,
           connect_options: [timeout: 5000],
           receive_timeout: 10_000,
           max_retries: 0
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, Error.api_error("Failed to fetch NZB from URL", %{status: status, url: url})}

      {:error, exception} ->
        {:error, Error.network_error("Failed to fetch NZB: #{inspect(exception)}")}
    end
  end

  defp map_priority(nil), do: 0
  defp map_priority(:low), do: -50
  defp map_priority(:normal), do: 0
  defp map_priority(:high), do: 50
  defp map_priority(_), do: 0
end
