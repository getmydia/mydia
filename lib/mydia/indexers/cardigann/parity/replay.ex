defmodule Mydia.Indexers.Cardigann.Parity.Replay do
  @moduledoc """
  Serves recorded exchanges to an engine in place of the network.

  Repeated requests for one key are answered in recorded order; once the queue
  is exhausted the last exchange repeats, so an engine that retries or pages
  past the capture still gets a stable answer. A request with no recorded
  exchange is a miss: it is remembered (see `misses/1`) and answered with a 404.

  A recorded transport error comes back from the Req plug as
  `{:error, %Req.TransportError{}}`. Raising from the plug does not do that in
  Req 0.7 (the exception escapes), so the plug uses the `:req_test_exception`
  private key that `Req.Test.transport_error/2` relies on.
  """

  use Agent

  alias Mydia.Indexers.Cardigann.Parity.Capture
  alias Mydia.Indexers.Cardigann.Parity.Capture.Exchange
  alias Mydia.Indexers.Cardigann.Parity.RequestKey

  @spec start_link(Capture.t()) :: {:ok, pid()}
  def start_link(%Capture{} = capture) do
    queues =
      Enum.reduce(capture.exchanges, %{}, fn %Exchange{request: key} = ex, acc ->
        Map.update(acc, key, [ex], &(&1 ++ [ex]))
      end)

    Agent.start_link(fn -> %{queues: queues, misses: []} end)
  end

  @spec fetch(pid(), RequestKey.t()) :: {:ok, Exchange.t()} | :miss
  def fetch(pid, %RequestKey{} = key) do
    Agent.get_and_update(pid, fn state ->
      case Map.get(state.queues, key) do
        nil ->
          {:miss, %{state | misses: [key | state.misses]}}

        [last] ->
          {{:ok, last}, state}

        [next | rest] ->
          {{:ok, next}, put_in(state.queues[key], rest)}
      end
    end)
  end

  @doc "Keys that had no recorded exchange, in request order."
  @spec misses(pid()) :: [RequestKey.t()]
  def misses(pid), do: pid |> Agent.get(& &1.misses) |> Enum.reverse()

  @doc "A closure for Req's `plug:` option."
  @spec req_plug(pid()) :: (Plug.Conn.t() -> Plug.Conn.t())
  def req_plug(pid) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      body = if body == "", do: nil, else: body
      key = RequestKey.new(conn.method, Plug.Conn.request_url(conn), body)

      case fetch(pid, key) do
        {:ok, %Exchange{error: error}} when not is_nil(error) ->
          # Req 0.7 does not rescue a raise from a plug. It does honour the
          # private key Req.Test.transport_error/2 sets, which turns the conn
          # into {:error, exception} for the caller.
          Plug.Conn.put_private(conn, :req_test_exception, %Req.TransportError{reason: error})

        {:ok, %Exchange{} = ex} ->
          conn =
            Enum.reduce(ex.headers, conn, fn {k, v}, c -> Plug.Conn.put_resp_header(c, k, v) end)

          Plug.Conn.send_resp(conn, ex.status, ex.body || "")

        :miss ->
          Plug.Conn.send_resp(conn, 404, "parity replay miss")
      end
    end
  end
end
