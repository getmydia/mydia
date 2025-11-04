defmodule Mydia.Downloads.Client.Qbittorrent do
  @moduledoc """
  qBittorrent download client adapter.

  Implements the download client behaviour for qBittorrent using its Web API.
  qBittorrent uses cookie-based authentication and a REST-like API.

  ## API Documentation

  qBittorrent Web API: https://github.com/qbittorrent/qBittorrent/wiki/WebUI-API-(qBittorrent-4.1)

  ## Authentication

  qBittorrent requires logging in via the `/api/v2/auth/login` endpoint to obtain
  a session cookie (`SID`). This cookie must be included in all subsequent requests.

  ## Configuration

  The adapter expects the following configuration:

      config = %{
        type: :qbittorrent,
        host: "localhost",
        port: 8080,
        username: "admin",
        password: "adminpass",
        use_ssl: false,
        options: %{
          timeout: 30_000,
          connect_timeout: 5_000
        }
      }

  ## State Mapping

  qBittorrent states are mapped to our internal states:

    * `downloading` -> `:downloading`
    * `uploading`, `stalledUP`, `forcedUP` -> `:seeding`
    * `pausedDL`, `pausedUP` -> `:paused`
    * `error`, `missingFiles` -> `:error`
    * `checkingDL`, `checkingUP`, `checkingResumeData` -> `:checking`
    * `queuedDL`, `queuedUP`, `allocating` -> `:downloading` (queued but counted as downloading)
  """

  @behaviour Mydia.Downloads.Client

  alias Mydia.Downloads.Client.{Error, HTTP}

  @impl true
  def test_connection(config) do
    with {:ok, req} <- authenticate(config),
         {:ok, response} <- HTTP.get(req, "/api/v2/app/version") do
      case response.status do
        200 ->
          {:ok, %{version: response.body, api_version: "2.x"}}

        _ ->
          {:error, Error.api_error("Unexpected response status", %{status: response.status})}
      end
    end
  end

  @impl true
  def add_torrent(config, torrent, opts \\ []) do
    with {:ok, req} <- authenticate(config),
         {:ok, body} <- build_add_torrent_body(torrent, opts),
         {:ok, response} <- HTTP.post(req, "/api/v2/torrents/add", body: body) do
      case response.status do
        200 ->
          # qBittorrent returns "Ok." on success but doesn't immediately return the hash
          # We need to extract the hash from the torrent or wait for it to appear
          extract_torrent_hash(torrent)

        _ ->
          {:error,
           Error.api_error("Failed to add torrent", %{
             status: response.status,
             body: response.body
           })}
      end
    end
  end

  @impl true
  def get_status(config, client_id) do
    with {:ok, req} <- authenticate(config),
         {:ok, response} <-
           HTTP.get(req, "/api/v2/torrents/info", params: [hashes: client_id]) do
      case response.status do
        200 ->
          case response.body do
            [torrent | _] ->
              {:ok, parse_torrent_status(torrent)}

            [] ->
              {:error, Error.not_found("Torrent not found")}
          end

        _ ->
          {:error, Error.api_error("Failed to get torrent status", %{status: response.status})}
      end
    end
  end

  @impl true
  def list_torrents(config, opts \\ []) do
    with {:ok, req} <- authenticate(config),
         params <- build_list_params(opts),
         {:ok, response} <- HTTP.get(req, "/api/v2/torrents/info", params: params) do
      case response.status do
        200 ->
          torrents =
            response.body
            |> Enum.map(&parse_torrent_status/1)

          {:ok, torrents}

        _ ->
          {:error, Error.api_error("Failed to list torrents", %{status: response.status})}
      end
    end
  end

  @impl true
  def remove_torrent(config, client_id, opts \\ []) do
    delete_files = Keyword.get(opts, :delete_files, false)

    with {:ok, req} <- authenticate(config),
         body <- %{hashes: client_id, deleteFiles: delete_files},
         {:ok, response} <- HTTP.post(req, "/api/v2/torrents/delete", form: body) do
      case response.status do
        200 ->
          :ok

        404 ->
          {:error, Error.not_found("Torrent not found")}

        _ ->
          {:error, Error.api_error("Failed to remove torrent", %{status: response.status})}
      end
    end
  end

  @impl true
  def pause_torrent(config, client_id) do
    with {:ok, req} <- authenticate(config),
         body <- %{hashes: client_id},
         {:ok, response} <- HTTP.post(req, "/api/v2/torrents/pause", form: body) do
      case response.status do
        200 ->
          :ok

        _ ->
          {:error, Error.api_error("Failed to pause torrent", %{status: response.status})}
      end
    end
  end

  @impl true
  def resume_torrent(config, client_id) do
    with {:ok, req} <- authenticate(config),
         body <- %{hashes: client_id},
         {:ok, response} <- HTTP.post(req, "/api/v2/torrents/resume", form: body) do
      case response.status do
        200 ->
          :ok

        _ ->
          {:error, Error.api_error("Failed to resume torrent", %{status: response.status})}
      end
    end
  end

  ## Private Functions

  defp authenticate(config) do
    unless config[:username] && config[:password] do
      {:error, Error.invalid_config("Username and password are required for qBittorrent")}
    else
      do_authenticate(config)
    end
  end

  defp do_authenticate(config) do
    req = HTTP.new_request(config)

    # qBittorrent uses form-encoded login
    login_body = %{
      username: config.username,
      password: config.password
    }

    case HTTP.post(req, "/api/v2/auth/login", form: login_body) do
      {:ok, %{status: 200} = response} ->
        # Extract SID cookie from response
        case extract_sid_cookie(response) do
          {:ok, sid} ->
            # Add cookie to request for future calls
            authenticated_req = Req.Request.put_header(req, "cookie", "SID=#{sid}")
            {:ok, authenticated_req}

          :error ->
            {:error, Error.authentication_failed("Failed to extract session cookie")}
        end

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

  defp extract_sid_cookie(response) do
    case Req.Response.get_header(response, "set-cookie") do
      [cookie | _] ->
        # Extract SID value from "SID=xxx; ..."
        case Regex.run(~r/SID=([^;]+)/, cookie) do
          [_, sid] -> {:ok, sid}
          _ -> :error
        end

      [] ->
        :error
    end
  end

  defp build_add_torrent_body({:magnet, magnet_link}, opts) do
    body =
      %{urls: magnet_link}
      |> add_optional_param(:category, opts[:category])
      |> add_optional_param(:tags, opts[:tags], &Enum.join(&1, ","))
      |> add_optional_param(:savepath, opts[:save_path])
      |> add_optional_param(:paused, opts[:paused])

    {:ok, body}
  end

  defp build_add_torrent_body({:file, file_contents}, opts) do
    # For file uploads, we need to use multipart
    body =
      %{torrents: file_contents}
      |> add_optional_param(:category, opts[:category])
      |> add_optional_param(:tags, opts[:tags], &Enum.join(&1, ","))
      |> add_optional_param(:savepath, opts[:save_path])
      |> add_optional_param(:paused, opts[:paused])

    {:ok, body}
  end

  defp build_add_torrent_body({:url, url}, opts) do
    body =
      %{urls: url}
      |> add_optional_param(:category, opts[:category])
      |> add_optional_param(:tags, opts[:tags], &Enum.join(&1, ","))
      |> add_optional_param(:savepath, opts[:save_path])
      |> add_optional_param(:paused, opts[:paused])

    {:ok, body}
  end

  defp add_optional_param(body, _key, nil), do: body

  defp add_optional_param(body, key, value) do
    Map.put(body, key, value)
  end

  defp add_optional_param(body, _key, nil, _transform), do: body

  defp add_optional_param(body, key, value, transform) when is_function(transform, 1) do
    Map.put(body, key, transform.(value))
  end

  defp extract_torrent_hash({:magnet, magnet_link}) do
    # Extract hash from magnet link (urn:btih:HASH)
    case Regex.run(~r/urn:btih:([a-fA-F0-9]{40})/i, magnet_link) do
      [_, hash] ->
        {:ok, String.downcase(hash)}

      _ ->
        {:error,
         Error.invalid_torrent("Could not extract hash from magnet link", %{
           magnet: magnet_link
         })}
    end
  end

  defp extract_torrent_hash({:file, _file_contents}) do
    # For file uploads, we can't easily get the hash without parsing the torrent
    # qBittorrent should return it, but the API doesn't provide it immediately
    # We'll need to poll for new torrents or use a different approach
    {:error,
     Error.api_error(
       "Hash extraction from file not yet implemented - use list_torrents to find the torrent"
     )}
  end

  defp extract_torrent_hash({:url, _url}) do
    # Similar issue as with files
    {:error,
     Error.api_error(
       "Hash extraction from URL not yet implemented - use list_torrents to find the torrent"
     )}
  end

  defp build_list_params(opts) do
    params = []

    params =
      case opts[:filter] do
        nil -> params
        :all -> params
        :downloading -> [{:filter, "downloading"} | params]
        :seeding -> [{:filter, "seeding"} | params]
        :completed -> [{:filter, "completed"} | params]
        :paused -> [{:filter, "paused"} | params]
        :active -> [{:filter, "active"} | params]
        :inactive -> [{:filter, "inactive"} | params]
        _ -> params
      end

    params =
      if opts[:category] do
        [{:category, opts[:category]} | params]
      else
        params
      end

    params =
      if opts[:tag] do
        [{:tag, opts[:tag]} | params]
      else
        params
      end

    params
  end

  defp parse_torrent_status(torrent) do
    %{
      id: torrent["hash"],
      name: torrent["name"],
      state: parse_state(torrent["state"]),
      progress: torrent["progress"] * 100,
      download_speed: torrent["dlspeed"] || 0,
      upload_speed: torrent["upspeed"] || 0,
      downloaded: torrent["downloaded"] || 0,
      uploaded: torrent["uploaded"] || 0,
      size: torrent["size"] || 0,
      eta: parse_eta(torrent["eta"]),
      ratio: torrent["ratio"] || 0.0,
      save_path: torrent["save_path"] || "",
      added_at: parse_timestamp(torrent["added_on"]),
      completed_at: parse_timestamp(torrent["completion_on"])
    }
  end

  defp parse_state(state) when is_binary(state) do
    case state do
      "downloading" -> :downloading
      "stalledDL" -> :downloading
      "metaDL" -> :downloading
      "forcedDL" -> :downloading
      "queuedDL" -> :downloading
      "allocating" -> :downloading
      "uploading" -> :seeding
      "stalledUP" -> :seeding
      "forcedUP" -> :seeding
      "queuedUP" -> :seeding
      "pausedDL" -> :paused
      "pausedUP" -> :paused
      "checkingDL" -> :checking
      "checkingUP" -> :checking
      "checkingResumeData" -> :checking
      "error" -> :error
      "missingFiles" -> :error
      "unknown" -> :error
      _ -> :error
    end
  end

  defp parse_eta(eta) when is_integer(eta) and eta > 0, do: eta
  defp parse_eta(_), do: nil

  defp parse_timestamp(timestamp) when is_integer(timestamp) and timestamp > 0 do
    DateTime.from_unix!(timestamp)
  end

  defp parse_timestamp(_), do: nil
end
