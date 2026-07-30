defmodule Mydia.Downloads.Client.Rtorrent do
  @moduledoc """
  rTorrent download client adapter.

  Implements the download client behaviour for rTorrent using its XML-RPC API.
  rTorrent exposes various commands via XML-RPC for torrent management.

  ## API Documentation

  rTorrent XML-RPC Reference: https://rtorrent-docs.readthedocs.io/en/latest/
  Commands Reference: https://kannibalox.github.io/rtorrent-docs/cmd-ref.html

  ## XML-RPC Format

  All requests use XML-RPC format. rTorrent uses method calls like:
  - `system.listMethods` - List available methods
  - `d.multicall2` - Query multiple torrent properties
  - `load.raw_start` - Add a torrent from binary data
  - `d.start`, `d.stop` - Control torrents

  ## Configuration

  The adapter expects the following configuration:

      config = %{
        type: :rtorrent,
        host: "localhost",
        port: 8080,
        username: "admin",     # optional, for HTTP Basic auth
        password: "adminpass", # optional, for HTTP Basic auth
        use_ssl: false,
        options: %{
          timeout: 30_000,
          connect_timeout: 5_000,
          rpc_path: "/RPC2"    # default path, can also be "/XMLRPC"
        }
      }

  ## State Mapping

  rTorrent states are mapped to our internal states based on:
  - `d.state`: 0 = stopped, 1 = started
  - `d.is_active`: 0 = inactive, 1 = active
  - `d.complete`: 0 = incomplete, 1 = complete
  - `d.is_hash_checking`: 0 = not checking, 1 = checking

  State mapping:
    * state=1, active=1, complete=0 -> `:downloading`
    * state=1, active=1, complete=1 -> `:seeding`
    * state=0, complete=0 -> `:paused`
    * state=0, complete=1 -> `:completed`
    * is_hash_checking=1 -> `:checking`

  ## Priority

  rTorrent supports per-torrent download priority via `d.priority.set`. Valid
  native integer values are `0` (off), `1` (low), `2` (normal), and `3`
  (high). When `priority_profile` is empty, this adapter passes no priority
  command and rTorrent uses its own default (`2`). When the profile supplies
  an override for an atom, the resolved value is appended as a
  `d.priority.set=N` command on the `load.start` / `load.raw_start` call.
  """

  @behaviour Mydia.Downloads.Client

  @impl true
  def supported_protocols, do: [:torrent]

  alias Mydia.Downloads.Client.{Error, HTTP}
  alias Mydia.Downloads.Priority
  alias Mydia.Downloads.Client.Helpers
  alias Mydia.Downloads.Structs.{ClientInfo, DownloadStatus}
  alias Mydia.Downloads.TorrentHash

  @impl true
  def test_connection(config) do
    case xmlrpc_call(config, "system.client_version", []) do
      {:ok, version} when is_binary(version) ->
        # Try to get library version as well for api_version
        api_version =
          case xmlrpc_call(config, "system.library_version", []) do
            {:ok, lib_version} -> lib_version
            _ -> "unknown"
          end

        {:ok, ClientInfo.new(version: version, api_version: api_version)}

      {:ok, _other} ->
        {:error, Error.api_error("Unexpected response from rTorrent")}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def add_torrent(config, torrent, opts \\ []) do
    {:ok, {method, args}} = build_load_command(torrent, opts, config)

    case xmlrpc_call(config, method, args) do
      {:ok, 0} ->
        # rTorrent returns 0 on success, we need to extract the hash
        extract_torrent_hash(torrent)

      {:ok, _} ->
        {:error, Error.api_error("Failed to add torrent to rTorrent")}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def get_status(config, client_id) do
    # Use d.multicall2 with the specific hash to get torrent info
    fields = torrent_fields()

    case xmlrpc_call(config, "d.multicall2", ["", "main", "d.hash=" <> client_id | fields]) do
      {:ok, [torrent_data | _]} when is_list(torrent_data) ->
        {:ok, parse_torrent_status(torrent_data, fields)}

      {:ok, []} ->
        {:error, Error.not_found("Torrent not found")}

      {:ok, _other} ->
        {:error, Error.api_error("Unexpected response format")}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def list_torrents(config, opts \\ []) do
    view = get_view_for_filter(opts[:filter])
    fields = torrent_fields()

    case xmlrpc_call(config, "d.multicall2", ["", view | fields]) do
      {:ok, torrents} when is_list(torrents) ->
        parsed_torrents =
          torrents
          |> Enum.map(&parse_torrent_status(&1, fields))
          |> apply_client_filters(opts)

        {:ok, parsed_torrents}

      {:ok, _other} ->
        {:error, Error.api_error("Unexpected response format")}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def remove_torrent(config, client_id, opts \\ []) do
    delete_files = Keyword.get(opts, :delete_files, false)

    # First erase the torrent from rTorrent
    case xmlrpc_call(config, "d.erase", [client_id]) do
      {:ok, 0} ->
        # If delete_files is requested, we need to handle that separately
        # rTorrent's d.erase only removes the torrent, not the data
        if delete_files do
          # Note: rTorrent doesn't have a built-in command to delete files
          # The user would need to handle this via custom commands or file system
          # For now, we just acknowledge the torrent removal
          :ok
        else
          :ok
        end

      {:ok, _} ->
        {:error, Error.api_error("Failed to remove torrent")}

      {:error, %Error{type: :api_error} = error} ->
        # Check if it's a "not found" error
        if String.contains?(error.message || "", "Could not find") do
          {:error, Error.not_found("Torrent not found")}
        else
          {:error, error}
        end

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def pause_torrent(config, client_id) do
    case xmlrpc_call(config, "d.stop", [client_id]) do
      {:ok, 0} ->
        :ok

      {:ok, _} ->
        {:error, Error.api_error("Failed to pause torrent")}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def resume_torrent(config, client_id) do
    case xmlrpc_call(config, "d.start", [client_id]) do
      {:ok, 0} ->
        :ok

      {:ok, _} ->
        {:error, Error.api_error("Failed to resume torrent")}

      {:error, _} = error ->
        error
    end
  end

  ## Private Functions

  # Build the XML-RPC load command based on torrent type
  defp build_load_command({:magnet, magnet_link}, opts, config) do
    # load.start takes the magnet URL and optional commands
    commands = build_load_options(opts, config)
    {:ok, {"load.start", ["", magnet_link | commands]}}
  end

  defp build_load_command({:file, file_contents}, opts, config) do
    # load.raw_start takes an empty target, binary data, and optional commands
    commands = build_load_options(opts, config)
    {:ok, {"load.raw_start", ["", {:base64, Base.encode64(file_contents)} | commands]}}
  end

  defp build_load_command({:url, url}, opts, config) do
    # load.start can also take HTTP URLs
    commands = build_load_options(opts, config)
    {:ok, {"load.start", ["", url | commands]}}
  end

  defp build_load_options(opts, config) do
    commands = []

    # Add save path if specified
    commands =
      if opts[:save_path] do
        ["d.directory.set=" <> opts[:save_path] | commands]
      else
        commands
      end

    # Add category/label as custom1
    commands =
      if opts[:category] do
        ["d.custom1.set=" <> opts[:category] | commands]
      else
        commands
      end

    # Handle paused state
    commands =
      if opts[:paused] do
        # Use d.state.set=0 to start paused
        ["d.state.set=0" | commands]
      else
        commands
      end

    # Add priority override when the profile resolves the atom to a value.
    # Empty profile -> nil -> no command appended (rTorrent default applies).
    commands =
      case map_priority(opts[:priority], config) do
        nil -> commands
        value -> ["d.priority.set=" <> to_string(value) | commands]
      end

    commands
  end

  # Resolves a Priority atom into rTorrent's `d.priority.set` integer.
  # When `priority_profile` is empty (the default), returns nil so no
  # priority command is appended and rTorrent's own default applies.
  defp map_priority(nil, _config), do: nil

  defp map_priority(atom, config) when atom in [:verylow, :low, :normal, :high, :veryhigh] do
    profile = Helpers.priority_profile(config)
    Priority.resolve(atom, profile, nil)
  end

  defp map_priority(_other, _config), do: nil

  # Fields to query for torrent status
  defp torrent_fields do
    [
      "d.hash=",
      "d.name=",
      "d.state=",
      "d.is_active=",
      "d.complete=",
      "d.is_hash_checking=",
      "d.bytes_done=",
      "d.size_bytes=",
      "d.down.rate=",
      "d.up.rate=",
      "d.up.total=",
      "d.ratio=",
      "d.directory=",
      # `d.base_path` is this torrent's own data — the file itself for a
      # single-file torrent, the torrent directory for a multi-file one.
      # `d.directory` alone is the *containing* directory for single-file
      # torrents, i.e. the shared download root, which MediaImport would then
      # recursively sweep into the wrong library folder.
      "d.base_path=",
      "d.timestamp.started=",
      "d.timestamp.finished="
    ]
  end

  defp parse_torrent_status(data, fields) when is_list(data) do
    # Build a map from field names to values
    field_map =
      fields
      |> Enum.zip(data)
      |> Enum.reduce(%{}, fn {field, value}, acc ->
        # Extract field name from "d.fieldname="
        key = field |> String.trim_trailing("=") |> String.replace("d.", "")
        Map.put(acc, key, value)
      end)

    state = parse_state(field_map)
    size = field_map["size_bytes"] || 0
    bytes_done = field_map["bytes_done"] || 0
    progress = if size > 0, do: bytes_done / size * 100.0, else: 0.0

    DownloadStatus.new(%{
      id: field_map["hash"],
      name: field_map["name"] || "",
      state: state,
      progress: progress,
      download_speed: field_map["down.rate"] || 0,
      upload_speed: field_map["up.rate"] || 0,
      downloaded: bytes_done,
      uploaded: field_map["up.total"] || 0,
      size: size,
      eta: calculate_eta(size, bytes_done, field_map["down.rate"] || 0),
      ratio: parse_ratio(field_map["ratio"]),
      save_path: field_map["directory"] || "",
      files: base_path_files(field_map["base_path"]),
      added_at: Helpers.parse_timestamp_unix(field_map["timestamp.started"]),
      completed_at: Helpers.parse_timestamp_unix(field_map["timestamp.finished"])
    })
  end

  # Scope the import to this torrent's own data. Empty until rTorrent has
  # allocated the torrent, in which case we leave `files` nil and the caller
  # falls back to `save_path`.
  defp base_path_files(base_path) when is_binary(base_path) and base_path != "",
    do: [base_path]

  defp base_path_files(_base_path), do: nil

  defp parse_state(field_map) do
    d_state = field_map["state"] || 0
    is_active = field_map["is_active"] || 0
    complete = field_map["complete"] || 0
    is_checking = field_map["is_hash_checking"] || 0

    cond do
      is_checking == 1 ->
        :checking

      d_state == 1 and is_active == 1 and complete == 0 ->
        :downloading

      d_state == 1 and is_active == 1 and complete == 1 ->
        :seeding

      d_state == 0 and complete == 1 ->
        :completed

      d_state == 0 ->
        :paused

      true ->
        :error
    end
  end

  defp calculate_eta(_size, _bytes_done, 0), do: nil

  defp calculate_eta(size, bytes_done, rate) when rate > 0 do
    remaining = size - bytes_done
    if remaining > 0, do: div(remaining, rate), else: 0
  end

  defp calculate_eta(_size, _bytes_done, _rate), do: nil

  defp parse_ratio(ratio) when is_integer(ratio) do
    # rTorrent stores ratio as integer with factor 1000 (1000 = 1.0)
    ratio / 1000.0
  end

  defp parse_ratio(ratio) when is_float(ratio), do: ratio
  defp parse_ratio(_), do: 0.0

  defp get_view_for_filter(nil), do: "main"
  defp get_view_for_filter(:all), do: "main"
  defp get_view_for_filter(:downloading), do: "incomplete"
  defp get_view_for_filter(:seeding), do: "seeding"
  defp get_view_for_filter(:completed), do: "complete"
  defp get_view_for_filter(:paused), do: "stopped"
  defp get_view_for_filter(:active), do: "active"
  defp get_view_for_filter(_), do: "main"

  defp apply_client_filters(torrents, opts) do
    # Additional client-side filtering if needed
    torrents =
      if opts[:category] do
        # Would need to fetch d.custom1 for category filtering
        # For now, return all torrents
        torrents
      else
        torrents
      end

    torrents
  end

  # Extract hash from torrent input using shared TorrentHash module
  defp extract_torrent_hash(torrent_input) do
    TorrentHash.extract(torrent_input)
  end

  # XML-RPC call implementation
  defp xmlrpc_call(config, method, params) do
    req = HTTP.new_request(config)
    rpc_path = get_in(config, [:options, :rpc_path]) || "/RPC2"

    # Build XML-RPC request body
    body = build_xmlrpc_request(method, params)

    case HTTP.post(req, rpc_path, body: body, headers: [{"content-type", "text/xml"}]) do
      {:ok, %{status: 200, body: response_body}} ->
        parse_xmlrpc_response(response_body)

      {:ok, %{status: 401}} ->
        {:error, Error.authentication_failed("Invalid username or password")}

      {:ok, %{status: 403}} ->
        {:error, Error.authentication_failed("Access forbidden")}

      {:ok, response} ->
        {:error, Error.api_error("Unexpected response status", %{status: response.status})}

      {:error, _} = error ->
        error
    end
  end

  # Build XML-RPC request body
  defp build_xmlrpc_request(method, params) do
    params_xml =
      params
      |> Enum.map_join("", &encode_xmlrpc_value/1)

    """
    <?xml version="1.0"?>
    <methodCall>
      <methodName>#{escape_xml(method)}</methodName>
      <params>#{params_xml}</params>
    </methodCall>
    """
  end

  defp encode_xmlrpc_value(value) when is_binary(value) do
    "<param><value><string>#{escape_xml(value)}</string></value></param>"
  end

  defp encode_xmlrpc_value(value) when is_integer(value) do
    "<param><value><i4>#{value}</i4></value></param>"
  end

  defp encode_xmlrpc_value(value) when is_float(value) do
    "<param><value><double>#{value}</double></value></param>"
  end

  defp encode_xmlrpc_value(true) do
    "<param><value><boolean>1</boolean></value></param>"
  end

  defp encode_xmlrpc_value(false) do
    "<param><value><boolean>0</boolean></value></param>"
  end

  defp encode_xmlrpc_value({:base64, encoded}) do
    "<param><value><base64>#{encoded}</base64></value></param>"
  end

  defp encode_xmlrpc_value(values) when is_list(values) do
    array_values =
      values
      |> Enum.map_join("", &encode_xmlrpc_array_value/1)

    "<param><value><array><data>#{array_values}</data></array></value></param>"
  end

  defp encode_xmlrpc_array_value(value) when is_binary(value) do
    "<value><string>#{escape_xml(value)}</string></value>"
  end

  defp encode_xmlrpc_array_value(value) when is_integer(value) do
    "<value><i4>#{value}</i4></value>"
  end

  defp encode_xmlrpc_array_value({:base64, encoded}) do
    "<value><base64>#{encoded}</base64></value>"
  end

  defp escape_xml(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp escape_xml(other), do: to_string(other)

  # Parse XML-RPC response
  defp parse_xmlrpc_response(body) when is_binary(body) do
    # Use SweetXml for parsing
    import SweetXml

    try do
      # Check if it's a fault response
      case xpath(body, ~x"//fault/value/struct"e) do
        nil ->
          # Parse successful response
          parse_xmlrpc_value(body, ~x"//methodResponse/params/param/value"e)

        _fault ->
          # Parse fault
          fault_code =
            xpath(body, ~x"//fault/value/struct/member[name='faultCode']/value/int/text()"s)

          fault_string =
            xpath(body, ~x"//fault/value/struct/member[name='faultString']/value/string/text()"s)

          {:error, Error.api_error("XML-RPC fault: #{fault_string}", %{code: fault_code})}
      end
    rescue
      e ->
        {:error, Error.parse_error("Failed to parse XML-RPC response: #{inspect(e)}")}
    end
  end

  defp parse_xmlrpc_response(_), do: {:error, Error.parse_error("Invalid response body")}

  defp parse_xmlrpc_value(body, xpath_expr) do
    import SweetXml

    case xpath(body, xpath_expr) do
      nil ->
        {:error, Error.parse_error("No value found in response")}

      value_node ->
        {:ok, extract_value(body, value_node)}
    end
  end

  defp extract_value(body, _value_node) do
    import SweetXml

    cond do
      # Try to extract string value
      (str = xpath(body, ~x"//methodResponse/params/param/value/string/text()"s)) != "" ->
        str

      # Try to extract integer value
      (int = xpath(body, ~x"//methodResponse/params/param/value/i4/text()"s)) != "" ->
        String.to_integer(int)

      (int = xpath(body, ~x"//methodResponse/params/param/value/int/text()"s)) != "" ->
        String.to_integer(int)

      # Try to extract double value
      (dbl = xpath(body, ~x"//methodResponse/params/param/value/double/text()"s)) != "" ->
        String.to_float(dbl)

      # Try to extract boolean value
      (bool = xpath(body, ~x"//methodResponse/params/param/value/boolean/text()"s)) != "" ->
        bool == "1"

      # Try to extract array value
      true ->
        extract_array_value(body)
    end
  end

  defp extract_array_value(body) do
    import SweetXml

    # First check if an array element exists at all (even if empty)
    has_array = xpath(body, ~x"//methodResponse/params/param/value/array"e) != nil

    if has_array do
      # Get array values - will be empty list if no <value> elements inside
      array_values = xpath(body, ~x"//methodResponse/params/param/value/array/data/value"el)
      Enum.map(array_values || [], &extract_single_array_element(body, &1))
    else
      # No array found, try to return raw text
      xpath(body, ~x"//methodResponse/params/param/value/text()"s)
    end
  end

  defp extract_single_array_element(_body, element) do
    import SweetXml

    # Each element could be a simple value or another array (for d.multicall results)
    inner_array = xpath(element, ~x"./array/data/value"el)

    if inner_array && inner_array != [] do
      # This is a nested array (like from d.multicall)
      Enum.map(inner_array, fn inner_elem ->
        extract_simple_value(inner_elem)
      end)
    else
      extract_simple_value(element)
    end
  end

  defp extract_simple_value(element) do
    import SweetXml

    cond do
      (str = xpath(element, ~x"./string/text()"s)) != "" ->
        str

      (int = xpath(element, ~x"./i4/text()"s)) != "" ->
        String.to_integer(int)

      (int = xpath(element, ~x"./int/text()"s)) != "" ->
        String.to_integer(int)

      (int = xpath(element, ~x"./i8/text()"s)) != "" ->
        String.to_integer(int)

      (dbl = xpath(element, ~x"./double/text()"s)) != "" ->
        String.to_float(dbl)

      (bool = xpath(element, ~x"./boolean/text()"s)) != "" ->
        bool == "1"

      true ->
        # Try to get direct text content
        text = xpath(element, ~x"./text()"s)
        if text != "", do: text, else: nil
    end
  end
end
