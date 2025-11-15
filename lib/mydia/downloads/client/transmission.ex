defmodule Mydia.Downloads.Client.Transmission do
  @moduledoc """
  Transmission download client adapter.

  Implements the download client behaviour for Transmission using its RPC API.
  Transmission uses JSON-RPC over HTTP with basic authentication and CSRF protection.

  ## API Documentation

  Transmission RPC Spec: https://github.com/transmission/transmission/blob/main/docs/rpc-spec.md

  ## CSRF Protection

  Transmission requires an `X-Transmission-Session-Id` header for all requests to prevent
  CSRF attacks. When a request is made without the correct session ID, the server responds
  with HTTP 409 and includes the valid session ID in the response headers. The client must
  extract this ID and retry the request with the `X-Transmission-Session-Id` header set.

  ## Configuration

  The adapter expects the following configuration:

      config = %{
        type: :transmission,
        host: "localhost",
        port: 9091,
        username: "admin",     # optional
        password: "adminpass", # optional
        use_ssl: false,
        options: %{
          timeout: 30_000,
          connect_timeout: 5_000,
          rpc_path: "/transmission/rpc"  # default path
        }
      }

  ## State Mapping

  Transmission status codes are mapped to our internal states:

    * `0` (stopped) -> `:paused`
    * `1` (queued to verify) -> `:checking`
    * `2` (verifying) -> `:checking`
    * `3` (queued to download) -> `:downloading`
    * `4` (downloading) -> `:downloading`
    * `5` (queued to seed) -> `:seeding`
    * `6` (seeding) -> `:seeding`

  ## JSON-RPC Format

  All requests use JSON-RPC format with sequential tag IDs:

      {
        "method": "torrent-get",
        "arguments": {"ids": [1], "fields": ["id", "name", "status"]},
        "tag": 1
      }
  """

  @behaviour Mydia.Downloads.Client

  alias Mydia.Downloads.Client.{Error, HTTP}
  alias Mydia.Downloads.Structs.{ClientInfo, TorrentStatus}

  # Sequential counter for RPC request tags
  @agent_name __MODULE__.TagCounter

  @doc false
  def start_link do
    Agent.start_link(fn -> 0 end, name: @agent_name)
  end

  @impl true
  def test_connection(config) do
    rpc_call(config, "session-get", %{})
    |> case do
      {:ok, response} ->
        version = get_in(response, ["arguments", "version"]) || "unknown"
        rpc_version = get_in(response, ["arguments", "rpc-version"]) || "unknown"

        {:ok, ClientInfo.new(version: version, rpc_version: rpc_version)}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def add_torrent(config, torrent, opts \\ []) do
    arguments = build_add_torrent_arguments(torrent, opts)

    rpc_call(config, "torrent-add", arguments)
    |> case do
      {:ok, %{"result" => "success", "arguments" => %{"torrent-added" => torrent_info}}} ->
        {:ok, torrent_info["hashString"]}

      {:ok, %{"result" => "success", "arguments" => %{"torrent-duplicate" => torrent_info}}} ->
        {:error, Error.duplicate_torrent("Torrent already exists", %{id: torrent_info["id"]})}

      {:ok, %{"result" => error_msg}} ->
        {:error, Error.api_error("Failed to add torrent", %{result: error_msg})}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def get_status(config, client_id) do
    # client_id is the torrent hash string
    torrent_id = parse_torrent_id(client_id)

    fields = [
      "id",
      "hashString",
      "name",
      "status",
      "percentDone",
      "rateDownload",
      "rateUpload",
      "downloadedEver",
      "uploadedEver",
      "totalSize",
      "eta",
      "uploadRatio",
      "downloadDir",
      "addedDate",
      "doneDate"
    ]

    arguments = %{
      "ids" => [torrent_id],
      "fields" => fields
    }

    rpc_call(config, "torrent-get", arguments)
    |> case do
      {:ok, %{"arguments" => %{"torrents" => [torrent | _]}}} ->
        {:ok, parse_torrent_status(torrent)}

      {:ok, %{"arguments" => %{"torrents" => []}}} ->
        {:error, Error.not_found("Torrent not found")}

      {:ok, %{"result" => error_msg}} ->
        {:error, Error.api_error("Failed to get torrent status", %{result: error_msg})}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def list_torrents(config, opts \\ []) do
    fields = [
      "id",
      "hashString",
      "name",
      "status",
      "percentDone",
      "rateDownload",
      "rateUpload",
      "downloadedEver",
      "uploadedEver",
      "totalSize",
      "eta",
      "uploadRatio",
      "downloadDir",
      "addedDate",
      "doneDate",
      "labels"
    ]

    arguments = %{"fields" => fields}

    # Add IDs filter if specified
    arguments =
      if opts[:ids] do
        Map.put(arguments, "ids", opts[:ids])
      else
        arguments
      end

    rpc_call(config, "torrent-get", arguments)
    |> case do
      {:ok, %{"arguments" => %{"torrents" => torrents}}} ->
        parsed_torrents =
          torrents
          |> Enum.map(&parse_torrent_status/1)
          |> apply_filters(opts)

        {:ok, parsed_torrents}

      {:ok, %{"result" => error_msg}} ->
        {:error, Error.api_error("Failed to list torrents", %{result: error_msg})}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def remove_torrent(config, client_id, opts \\ []) do
    # client_id is the torrent hash string
    torrent_id = parse_torrent_id(client_id)
    delete_files = Keyword.get(opts, :delete_files, false)

    arguments = %{
      "ids" => [torrent_id],
      "delete-local-data" => delete_files
    }

    rpc_call(config, "torrent-remove", arguments)
    |> case do
      {:ok, %{"result" => "success"}} ->
        :ok

      {:ok, %{"result" => error_msg}} ->
        {:error, Error.api_error("Failed to remove torrent", %{result: error_msg})}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def pause_torrent(config, client_id) do
    # client_id is the torrent hash string
    torrent_id = parse_torrent_id(client_id)
    arguments = %{"ids" => [torrent_id]}

    rpc_call(config, "torrent-stop", arguments)
    |> case do
      {:ok, %{"result" => "success"}} ->
        :ok

      {:ok, %{"result" => error_msg}} ->
        {:error, Error.api_error("Failed to pause torrent", %{result: error_msg})}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def resume_torrent(config, client_id) do
    # client_id is the torrent hash string
    torrent_id = parse_torrent_id(client_id)
    arguments = %{"ids" => [torrent_id]}

    rpc_call(config, "torrent-start", arguments)
    |> case do
      {:ok, %{"result" => "success"}} ->
        :ok

      {:ok, %{"result" => error_msg}} ->
        {:error, Error.api_error("Failed to resume torrent", %{result: error_msg})}

      {:error, _} = error ->
        error
    end
  end

  ## Private Functions

  # Makes an RPC call with automatic session ID handling
  defp rpc_call(config, method, arguments, session_id \\ nil) do
    req = HTTP.new_request(config)
    rpc_path = get_in(config, [:options, :rpc_path]) || "/transmission/rpc"

    # Add session ID header if we have one
    req =
      if session_id do
        Req.Request.put_header(req, "x-transmission-session-id", session_id)
      else
        req
      end

    # Build RPC request body
    body = %{
      "method" => method,
      "arguments" => arguments,
      "tag" => next_tag()
    }

    case HTTP.post(req, rpc_path, json: body) do
      {:ok, %{status: 409} = response} ->
        # Extract session ID from response and retry
        case extract_session_id(response) do
          {:ok, new_session_id} ->
            rpc_call(config, method, arguments, new_session_id)

          :error ->
            {:error,
             Error.api_error("Failed to extract session ID from 409 response", %{
               headers: response.headers
             })}
        end

      {:ok, %{status: 200} = response} ->
        {:ok, response.body}

      {:ok, %{status: 401}} ->
        {:error, Error.authentication_failed("Invalid username or password")}

      {:ok, response} ->
        {:error, Error.api_error("Unexpected response status", %{status: response.status})}

      {:error, _} = error ->
        error
    end
  end

  defp extract_session_id(response) do
    case Req.Response.get_header(response, "x-transmission-session-id") do
      [session_id | _] -> {:ok, session_id}
      [] -> :error
    end
  end

  defp next_tag do
    case Process.whereis(@agent_name) do
      nil ->
        # Agent not started, use random tag
        :rand.uniform(1_000_000)

      _pid ->
        Agent.get_and_update(@agent_name, fn count ->
          new_count = count + 1
          {new_count, new_count}
        end)
    end
  end

  defp build_add_torrent_arguments({:magnet, magnet_link}, opts) do
    %{"filename" => magnet_link}
    |> add_common_torrent_opts(opts)
  end

  defp build_add_torrent_arguments({:file, file_contents}, opts) do
    # Transmission expects base64-encoded metainfo
    metainfo = Base.encode64(file_contents)

    %{"metainfo" => metainfo}
    |> add_common_torrent_opts(opts)
  end

  defp build_add_torrent_arguments({:url, url}, opts) do
    %{"filename" => url}
    |> add_common_torrent_opts(opts)
  end

  defp add_common_torrent_opts(arguments, opts) do
    arguments
    |> add_optional_arg("download-dir", opts[:save_path])
    |> add_optional_arg("paused", opts[:paused])
    |> add_optional_arg("labels", opts[:tags])
  end

  defp add_optional_arg(arguments, _key, nil), do: arguments

  defp add_optional_arg(arguments, key, value) do
    Map.put(arguments, key, value)
  end

  defp parse_torrent_status(torrent) do
    # Build the full path to the torrent's files
    # Transmission stores files in downloadDir/torrentName/
    download_dir = torrent["downloadDir"] || ""
    torrent_name = torrent["name"] || ""

    save_path =
      if download_dir != "" and torrent_name != "" do
        Path.join(download_dir, torrent_name)
      else
        download_dir
      end

    TorrentStatus.new(%{
      id: torrent["hashString"],
      name: torrent_name,
      state: parse_state(torrent["status"]),
      progress: (torrent["percentDone"] || 0.0) * 100.0,
      download_speed: torrent["rateDownload"] || 0,
      upload_speed: torrent["rateUpload"] || 0,
      downloaded: torrent["downloadedEver"] || 0,
      uploaded: torrent["uploadedEver"] || 0,
      size: torrent["totalSize"] || 0,
      eta: parse_eta(torrent["eta"]),
      ratio: torrent["uploadRatio"] || 0.0,
      save_path: save_path,
      added_at: parse_timestamp(torrent["addedDate"]),
      completed_at: parse_timestamp(torrent["doneDate"])
    })
  end

  defp parse_state(status) when is_integer(status) do
    case status do
      0 -> :paused
      1 -> :checking
      2 -> :checking
      3 -> :downloading
      4 -> :downloading
      5 -> :seeding
      6 -> :seeding
      _ -> :error
    end
  end

  defp parse_eta(eta) when is_integer(eta) and eta >= 0, do: eta
  defp parse_eta(_), do: nil

  defp parse_timestamp(timestamp) when is_integer(timestamp) and timestamp > 0 do
    DateTime.from_unix!(timestamp)
  end

  defp parse_timestamp(_), do: nil

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

  defp filter_by_category(torrents, nil), do: torrents
  defp filter_by_category(torrents, _category), do: torrents

  defp filter_by_tag(torrents, nil), do: torrents
  defp filter_by_tag(torrents, _tag), do: torrents

  # Transmission RPC API accepts both hash strings and numeric IDs
  # Since we now use hash strings, just pass them through
  defp parse_torrent_id(id), do: id
end
