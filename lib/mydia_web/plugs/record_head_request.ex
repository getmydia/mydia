defmodule MydiaWeb.Plugs.RecordHeadRequest do
  @moduledoc """
  Remembers that a request was a `HEAD` before `Plug.Head` rewrites it to `GET`.

  Must run before `Plug.Head`. Handlers that would otherwise do expensive work
  for a body that is discarded (proxying a range from object storage) check
  `head_request?/1`.
  """

  @behaviour Plug

  import Plug.Conn, only: [put_private: 3]

  @key :mydia_head_request

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts), do: put_private(conn, @key, conn.method == "HEAD")

  @doc "True when the request was a HEAD, even after `Plug.Head` made it a GET."
  @spec head_request?(Plug.Conn.t()) :: boolean()
  def head_request?(%Plug.Conn{method: "HEAD"}), do: true
  def head_request?(%Plug.Conn{private: private}), do: Map.get(private, @key, false)
end
