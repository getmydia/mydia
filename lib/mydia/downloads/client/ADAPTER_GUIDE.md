# Download Client Adapter Implementation Guide

This guide explains how to implement a new download client adapter for the Mydia application.

## Overview

Download client adapters provide a standardized interface for interacting with different torrent clients (qBittorrent, Transmission, etc.). All adapters implement the `Mydia.Downloads.Client` behaviour.

## Architecture

The download client system consists of:

1. **Behaviour Module** (`Mydia.Downloads.Client`) - Defines the interface all adapters must implement
2. **Error Module** (`Mydia.Downloads.Client.Error`) - Common error types and handling
3. **Registry** (`Mydia.Downloads.Client.Registry`) - Runtime adapter selection
4. **HTTP Client** (`Mydia.Downloads.Client.HTTP`) - Shared HTTP utilities using Req
5. **Adapter Implementations** - Specific client adapters (e.g., `QBittorrent`, `Transmission`)

## Implementing a New Adapter

### Step 1: Create the Adapter Module

Create a new module in `lib/mydia/downloads/client/` that implements the behaviour:

```elixir
defmodule Mydia.Downloads.Client.MyClient do
  @moduledoc """
  Download client adapter for MyClient.

  ## Configuration

  The adapter expects the following configuration:

      %{
        type: :my_client,
        host: "localhost",
        port: 9091,
        username: "admin",
        password: "password",
        use_ssl: false,
        options: %{
          # MyClient-specific options
          rpc_path: "/transmission/rpc"
        }
      }
  """

  @behaviour Mydia.Downloads.Client

  alias Mydia.Downloads.Client.{Error, HTTP}

  @impl true
  def test_connection(config) do
    # Implementation
  end

  @impl true
  def add_torrent(config, torrent, opts \\ []) do
    # Implementation
  end

  @impl true
  def get_status(config, client_id) do
    # Implementation
  end

  @impl true
  def list_torrents(config, opts \\ []) do
    # Implementation
  end

  @impl true
  def remove_torrent(config, client_id, opts \\ []) do
    # Implementation
  end

  @impl true
  def pause_torrent(config, client_id) do
    # Implementation
  end

  @impl true
  def resume_torrent(config, client_id) do
    # Implementation
  end
end
```

### Step 2: Implement test_connection/1

This callback tests if the client is reachable and returns version information:

```elixir
@impl true
def test_connection(config) do
  req = HTTP.new_request(config)

  case HTTP.get(req, "/api/version") do
    {:ok, %{status: 200, body: body}} ->
      {:ok, %{
        version: body["version"],
        api_version: body["api_version"]
      }}

    {:ok, %{status: 401}} ->
      {:error, Error.authentication_failed("Invalid credentials")}

    {:ok, response} ->
      {:error, Error.api_error("Unexpected response", %{status: response.status})}

    {:error, error} ->
      {:error, error}
  end
end
```

### Step 3: Implement add_torrent/3

This callback adds a torrent to the client:

```elixir
@impl true
def add_torrent(config, torrent, opts \\ []) do
  req = HTTP.new_request(config)

  # Build request body based on torrent type
  body = build_add_torrent_body(torrent, opts)

  case HTTP.post(req, "/api/torrents/add", body: body) do
    {:ok, %{status: 200, body: %{"id" => client_id}}} ->
      {:ok, client_id}

    {:ok, %{status: 409}} ->
      {:error, Error.duplicate_torrent("Torrent already exists")}

    {:ok, response} ->
      {:error, Error.api_error("Failed to add torrent", %{status: response.status})}

    {:error, error} ->
      {:error, error}
  end
end

defp build_add_torrent_body({:magnet, url}, opts) do
  %{
    urls: url,
    category: opts[:category],
    tags: opts[:tags] && Enum.join(opts[:tags], ","),
    savepath: opts[:save_path],
    paused: opts[:paused] || false
  }
  |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  |> Map.new()
end

defp build_add_torrent_body({:file, contents}, opts) do
  # Handle file upload - specific to client API
  # Some clients use multipart/form-data
  %{
    torrents: contents,
    category: opts[:category],
    savepath: opts[:save_path]
  }
end

defp build_add_torrent_body({:url, url}, opts) do
  # Similar to magnet
  build_add_torrent_body({:magnet, url}, opts)
end
```

### Step 4: Implement get_status/2

This callback retrieves status for a specific torrent:

```elixir
@impl true
def get_status(config, client_id) do
  req = HTTP.new_request(config)

  case HTTP.get(req, "/api/torrents/info", params: [hashes: client_id]) do
    {:ok, %{status: 200, body: [torrent]}} ->
      {:ok, normalize_status(torrent)}

    {:ok, %{status: 200, body: []}} ->
      {:error, Error.not_found("Torrent not found")}

    {:ok, response} ->
      {:error, Error.api_error("Failed to get status", %{status: response.status})}

    {:error, error} ->
      {:error, error}
  end
end

defp normalize_status(raw_status) do
  %{
    id: raw_status["hash"],
    name: raw_status["name"],
    state: normalize_state(raw_status["state"]),
    progress: raw_status["progress"] * 100,
    download_speed: raw_status["dlspeed"],
    upload_speed: raw_status["upspeed"],
    downloaded: raw_status["downloaded"],
    uploaded: raw_status["uploaded"],
    size: raw_status["size"],
    eta: calculate_eta(raw_status),
    ratio: raw_status["ratio"],
    save_path: raw_status["save_path"],
    added_at: parse_timestamp(raw_status["added_on"]),
    completed_at: parse_timestamp(raw_status["completion_on"])
  }
end

defp normalize_state(state) when state in ["downloading", "metaDL", "forcedDL"], do: :downloading
defp normalize_state(state) when state in ["uploading", "stalledUP", "forcedUP"], do: :seeding
defp normalize_state("pausedDL"), do: :paused
defp normalize_state("error"), do: :error
defp normalize_state(_), do: :completed
```

### Step 5: Implement list_torrents/2

This callback lists all torrents with optional filtering:

```elixir
@impl true
def list_torrents(config, opts \\ []) do
  req = HTTP.new_request(config)
  params = build_list_params(opts)

  case HTTP.get(req, "/api/torrents/info", params: params) do
    {:ok, %{status: 200, body: torrents}} when is_list(torrents) ->
      statuses = Enum.map(torrents, &normalize_status/1)
      {:ok, statuses}

    {:ok, response} ->
      {:error, Error.api_error("Failed to list torrents", %{status: response.status})}

    {:error, error} ->
      {:error, error}
  end
end

defp build_list_params(opts) do
  [
    filter: filter_param(opts[:filter]),
    category: opts[:category],
    tag: opts[:tag]
  ]
  |> Enum.reject(fn {_k, v} -> is_nil(v) end)
end

defp filter_param(:downloading), do: "downloading"
defp filter_param(:seeding), do: "seeding"
defp filter_param(:completed), do: "completed"
defp filter_param(:paused), do: "paused"
defp filter_param(_), do: "all"
```

### Step 6: Implement remove_torrent/3

This callback removes a torrent:

```elixir
@impl true
def remove_torrent(config, client_id, opts \\ []) do
  req = HTTP.new_request(config)
  delete_files = Keyword.get(opts, :delete_files, false)

  body = %{hashes: client_id, deleteFiles: delete_files}

  case HTTP.post(req, "/api/torrents/delete", json: body) do
    {:ok, %{status: 200}} ->
      :ok

    {:ok, %{status: 404}} ->
      {:error, Error.not_found("Torrent not found")}

    {:ok, response} ->
      {:error, Error.api_error("Failed to remove torrent", %{status: response.status})}

    {:error, error} ->
      {:error, error}
  end
end
```

### Step 7: Implement pause_torrent/2 and resume_torrent/2

```elixir
@impl true
def pause_torrent(config, client_id) do
  req = HTTP.new_request(config)

  case HTTP.post(req, "/api/torrents/pause", json: %{hashes: client_id}) do
    {:ok, %{status: 200}} -> :ok
    {:ok, response} -> {:error, Error.api_error("Failed to pause", %{status: response.status})}
    {:error, error} -> {:error, error}
  end
end

@impl true
def resume_torrent(config, client_id) do
  req = HTTP.new_request(config)

  case HTTP.post(req, "/api/torrents/resume", json: %{hashes: client_id}) do
    {:ok, %{status: 200}} -> :ok
    {:ok, response} -> {:error, Error.api_error("Failed to resume", %{status: response.status})}
    {:error, error} -> {:error, error}
  end
end
```

### Optional callbacks

Two callbacks are optional. The `Mydia.Downloads.Client` facade checks
`function_exported?/3` and returns `{:error, :unsupported}` for an adapter that
leaves one out, so callers never need to know which adapters have it.

- `list_files/2`: a leaf-level listing of a torrent's files. See its `@doc`.
- `set_share_limits/3`: per-torrent share limits, called best effort at grab by
  `Mydia.Downloads.SeedingLimits` with
  `%{ratio: float | nil, seed_time: seconds | nil}`. Apply what the client
  supports and return `:ok`. qBittorrent takes both (`setShareLimits`, seed
  time in minutes, `-1` for an unset limit); Transmission takes the ratio only
  (`torrent-set` with `seedRatioLimit` and `seedRatioMode: 1`). rTorrent and
  rqbit leave it out.

Whatever the limits, `Mydia.Downloads.ClientRemoval` keeps a download in the
client until its tracker's seeding goal is met, so a client that takes no
limits is still safe. For that guard, fill `DownloadStatus.seeding_time`
(seconds) in `get_status/2` when the client counts it; otherwise the guard
falls back to the time since `completed_at`.

### Step 8: Register the Adapter

The `Registry` is the **single source of truth** for `type -> adapter module`. Every
resolution site (`queue`, `history`, `untracked_matcher`, `client_health`,
`media_import`) calls `Registry.lookup/1` or `Registry.get_adapter/1`, so registering
once is all that is needed — there are no per-module dispatch tables to update.

Add one line to `Mydia.Downloads.register_clients/0` in `lib/mydia/downloads.ex`:

```elixir
def register_clients do
  # ... existing registrations ...
  Registry.register(:my_client, Mydia.Downloads.Client.MyClient)
  :ok
end
```

`register_clients/0` runs at application startup (via the supervision tree), so the
adapter is available in every environment. You also need to add `:my_client` to the
config enum (`lib/mydia/settings/download_client_config.ex`) and the admin UI type
dropdown so operators can select it — see the existing client entries for the pattern.

### Step 9: Write Tests

Create tests in `test/mydia/downloads/client/my_client_test.exs`:

```elixir
defmodule Mydia.Downloads.Client.MyClientTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.Client.MyClient
  alias Mydia.Downloads.Client.Error

  @config %{
    type: :my_client,
    host: "localhost",
    port: 9091,
    username: "admin",
    password: "password",
    use_ssl: false,
    options: %{}
  }

  describe "test_connection/1" do
    test "returns version info on success" do
      # Use a mock HTTP client or integration test
      assert {:ok, %{version: _}} = MyClient.test_connection(@config)
    end

    test "returns authentication error with invalid credentials" do
      bad_config = %{@config | username: "wrong"}
      assert {:error, %Error{type: :authentication_failed}} = MyClient.test_connection(bad_config)
    end
  end

  # ... more tests ...
end
```

## Best Practices

1. **Error Handling**: Always use the `Error` module for consistent error types
2. **HTTP Client**: Use the shared `HTTP` module for all network requests
3. **State Normalization**: Convert client-specific states to standard states
4. **Timestamps**: Handle various timestamp formats (Unix, ISO8601, etc.)
5. **Options**: Support standard options and document client-specific ones
6. **Validation**: Validate configuration in `test_connection/1`
7. **Testing**: Write comprehensive tests including error cases
8. **Documentation**: Document all client-specific configuration options

## Common Patterns

### Handling Authentication Sessions

Some clients require login before making requests:

```elixir
defp ensure_authenticated(config) do
  case get_auth_cookie(config) do
    {:ok, cookie} ->
      {:ok, Map.put(config, :auth_cookie, cookie)}

    {:error, _} = error ->
      error
  end
end

defp get_auth_cookie(config) do
  req = HTTP.new_request(config)

  case HTTP.post(req, "/login", json: %{username: config.username, password: config.password}) do
    {:ok, %{status: 200, headers: headers}} ->
      cookie = extract_cookie(headers)
      {:ok, cookie}

    {:ok, _} ->
      {:error, Error.authentication_failed("Login failed")}

    {:error, error} ->
      {:error, error}
  end
end
```

### Handling Rate Limiting

```elixir
defp make_request_with_retry(req, path, opts, retries \\ 3) do
  case HTTP.get(req, path, opts) do
    {:ok, %{status: 429}} when retries > 0 ->
      Process.sleep(1000)
      make_request_with_retry(req, path, opts, retries - 1)

    result ->
      result
  end
end
```

### Working with Multipart Forms

```elixir
defp upload_torrent_file(req, file_contents, opts) do
  multipart = Multipart.new()
              |> Multipart.add_part(Multipart.Part.file_content_field("torrents", file_contents, "file.torrent"))
              |> Multipart.add_part(Multipart.Part.text_field("category", opts[:category] || ""))

  HTTP.post(req, "/api/torrents/add", body: Multipart.body(multipart), headers: Multipart.headers(multipart))
end
```

## Reference Implementation

See `lib/mydia/downloads/client/qbittorrent.ex` for a complete reference implementation.

## Additional Resources

- [Req Documentation](https://hexdocs.pm/req)
- [Mydia.Downloads.Client Behaviour](client.ex)
- [HTTP Client Module](http.ex)
- [Error Types](error.ex)
