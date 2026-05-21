defmodule MydiaWeb.Plugs.ParityCapture do
  @moduledoc """
  Captures GraphQL request/response pairs to a JSONL file for the
  mydia-rs GraphQL parity replay harness (U13).

  Off by default. Enabled by setting `MYDIA_PARITY_CAPTURE` to an
  absolute file path on Phoenix boot:

      MYDIA_PARITY_CAPTURE=/tmp/parity.jsonl ./dev up

  When set, every GraphQL HTTP request to `/api/graphql` is appended
  as one JSON-encoded line containing the request and the Phoenix-
  produced response. The Rust corpus reader at
  `mydia-rs/crates/parity-harness/src/corpus.rs` deserialises these
  records.

  Capture is best-effort. Any failure (disk full, permission denied,
  malformed body) is swallowed with a logged warning so the plug
  never breaks the GraphQL request lifecycle.

  Placement in `endpoint.ex` is **after** `Plug.Parsers` so
  `conn.body_params` carries the decoded GraphQL operation, and
  **before** `MydiaWeb.Router` so the `register_before_send`
  callback fires for the resolver's response.

  Record shape (one JSON object per line, keys may appear in any
  order — the Rust reader matches by key, not byte sequence):

      {
        "ts": "2026-05-21T12:34:56.789Z",
        "operation": "MoviesQuery" or null,
        "query": "query MoviesQuery { movies { ... } }",
        "variables": {"first": 20},
        "response": {"data": {...}, "errors": [...]},
        "status": 200,
        "elapsed_ms": 23
      }
  """

  @behaviour Plug

  require Logger

  @env_var "MYDIA_PARITY_CAPTURE"
  @graphql_path_prefix "/api/graphql"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case capture_path() do
      nil ->
        conn

      path ->
        if should_capture?(conn) do
          install_capture(conn, path)
        else
          conn
        end
    end
  end

  defp capture_path do
    case System.get_env(@env_var) do
      nil -> nil
      "" -> nil
      path -> path
    end
  end

  # Only capture POSTs to /api/graphql; ignore GraphiQL HTML pulls and
  # subscription WebSocket upgrades (which don't go through this
  # request pipeline anyway).
  defp should_capture?(%Plug.Conn{method: "POST", request_path: path}) do
    path == @graphql_path_prefix or
      String.starts_with?(path, @graphql_path_prefix <> "/")
  end

  defp should_capture?(_), do: false

  defp install_capture(conn, path) do
    start_us = System.monotonic_time(:microsecond)
    request_record = build_request_record(conn)

    Plug.Conn.register_before_send(conn, fn conn ->
      try do
        elapsed_ms = div(System.monotonic_time(:microsecond) - start_us, 1000)
        record = finalize_record(request_record, conn, elapsed_ms)
        append_record(path, record)
      rescue
        err ->
          Logger.warning("parity_capture: failed to record request: #{inspect(err)}")
      end

      conn
    end)
  end

  defp build_request_record(conn) do
    body_params = conn.body_params || %{}

    %{
      "query" => fetch_string(body_params, "query"),
      "variables" => fetch_object(body_params, "variables"),
      "operation" => fetch_string(body_params, "operationName")
    }
  end

  defp finalize_record(request_record, conn, elapsed_ms) do
    request_record
    |> Map.put("ts", DateTime.utc_now() |> DateTime.to_iso8601())
    |> Map.put("status", conn.status || 0)
    |> Map.put("elapsed_ms", elapsed_ms)
    |> Map.put("response", decode_response_body(conn.resp_body))
  end

  defp fetch_string(params, key) do
    case Map.get(params, key) || Map.get(params, String.to_atom(key)) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp fetch_object(params, key) do
    case Map.get(params, key) || Map.get(params, String.to_atom(key)) do
      value when is_map(value) -> value
      _ -> nil
    end
  end

  defp decode_response_body(nil), do: nil

  defp decode_response_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{"_unparseable_body" => body}
    end
  end

  defp decode_response_body(iodata) when is_list(iodata) do
    decode_response_body(IO.iodata_to_binary(iodata))
  end

  defp decode_response_body(_), do: nil

  defp append_record(path, record) do
    case Jason.encode(record) do
      {:ok, line} ->
        case File.open(path, [:append, :utf8]) do
          {:ok, io} ->
            try do
              IO.write(io, [line, "\n"])
            after
              File.close(io)
            end

          {:error, reason} ->
            Logger.warning("parity_capture: cannot open #{path}: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.warning("parity_capture: cannot encode record: #{inspect(reason)}")
    end
  end
end
