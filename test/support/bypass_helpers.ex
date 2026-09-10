defmodule Mydia.BypassHelpers do
  @moduledoc """
  Bypass stubs that match on the raw request path.

  Bypass routes on path segments and drops empty ones, so a stub registered
  for `/api` also answers `//api`, and a test for a double-slash bug passes
  with the bug still in place (#765). These helpers compare
  `conn.request_path` and send any other path to a fallback responder.
  """

  @doc """
  Stubs `method` on `path` to answer with `json_body` only when the raw
  request path is exactly `path`. Anything else reaching the same route goes
  to the fallback.

  ## Options

    - `:status` - HTTP status for the JSON response (default: 200)
    - `:fallback` - `(Plug.Conn.t() -> Plug.Conn.t())` for any other path
      (default: a 404)
  """
  def stub_exact_json(bypass, method, path, json_body, opts \\ []) do
    status = Keyword.get(opts, :status, 200)
    fallback = Keyword.get(opts, :fallback, &not_found/1)

    Bypass.stub(bypass, method, path, fn conn ->
      if conn.request_path == path do
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(status, json_body)
      else
        fallback.(conn)
      end
    end)
  end

  defp not_found(conn), do: Plug.Conn.resp(conn, 404, "Not Found")
end
