defmodule Mydia.Test.ConnectProxy do
  @moduledoc """
  A tiny in-test HTTP proxy that records request lines.

  `start/1` opens a loopback `:gen_tcp` listener under the calling test's
  supervisor (`ExUnit.Callbacks.start_supervised!/2`), so it is torn down with
  the test. It accepts any number of connections, reads each request head and
  records its first line (`"CONNECT 203.0.113.10:443 HTTP/1.1"`,
  `"GET http://tracker.example.test:4000/x HTTP/1.1"`), readable with
  `requests/1`.

  Options:

    * `respond: :forward` (default) - forwards the connection to
      `127.0.0.1:<port>`, taking the port from the CONNECT authority or the
      absolute-form URL and **ignoring the host**. CONNECT gets
      `HTTP/1.1 200 Connection established` and then both directions are piped;
      an absolute-form request has its head replayed to the target and is then
      piped.
    * `respond: {:status, status}` - answers `status` and closes.

  ## Test topology

  `Mydia.Net.Proxy.route/2` sends loopback and single-label hosts direct, so a
  test cannot reach a loopback Bypass server through the proxy by its real
  address. Instead it addresses the target as
  `http://tracker.example.test:<bypass_port>`: that name has a dot and is not
  an IP literal, so it is proxied; Mint hands the name to the proxy without
  resolving it locally; and `:forward` maps it back to loopback by keeping only
  the port. `.test` is an RFC 2606 reserved TLD, so `Mydia.RelayGuard` lets it
  through.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 2]

  @recv_timeout 5_000

  @type respond :: :forward | {:status, pos_integer()}

  @doc "Starts a proxy under the current test's supervisor."
  @spec start(keyword()) :: {:ok, %{port: :inet.port_number(), log: pid()}}
  def start(opts \\ []) do
    respond = Keyword.get(opts, :respond, :forward)
    log = start_supervised!({Agent, fn -> [] end}, id: make_ref())
    parent = self()
    ref = make_ref()

    start_supervised!({Task, fn -> listen(parent, ref, log, respond) end}, id: make_ref())

    receive do
      {^ref, port} -> {:ok, %{port: port, log: log}}
    after
      @recv_timeout -> raise "ConnectProxy did not start"
    end
  end

  @doc "The request lines recorded so far, oldest first."
  @spec requests(pid()) :: [String.t()]
  def requests(log), do: log |> Agent.get(& &1) |> Enum.reverse()

  defp listen(parent, ref, log, respond) do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :raw,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)
    send(parent, {ref, port})
    accept_loop(listen, log, respond)
  end

  defp accept_loop(listen, log, respond) do
    {:ok, socket} = :gen_tcp.accept(listen)
    # Linked, so every handler dies with the acceptor when the test ends.
    pid = spawn_link(fn -> handle(log, respond) end)
    :ok = :gen_tcp.controlling_process(socket, pid)
    send(pid, {:socket, socket})
    accept_loop(listen, log, respond)
  end

  defp handle(log, respond) do
    socket =
      receive do
        {:socket, socket} -> socket
      end

    case read_head(socket, "") do
      {:ok, head, rest} ->
        [line | _] = String.split(head, "\r\n", parts: 2)
        Agent.update(log, &[line | &1])
        respond(socket, respond, line, head, rest)

      :error ->
        :gen_tcp.close(socket)
    end
  end

  defp read_head(socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        {:ok, head <> "\r\n\r\n", rest}

      [_] ->
        case :gen_tcp.recv(socket, 0, @recv_timeout) do
          {:ok, data} -> read_head(socket, acc <> data)
          {:error, _} -> :error
        end
    end
  end

  defp respond(socket, {:status, status}, _line, _head, _rest) do
    :gen_tcp.send(
      socket,
      "HTTP/1.1 #{status} Proxy Test\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
    )

    :gen_tcp.close(socket)
  end

  defp respond(socket, :forward, line, head, rest) do
    {method, port} = parse_target(line)

    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw]) do
      {:ok, upstream} ->
        if method == "CONNECT" do
          :gen_tcp.send(socket, "HTTP/1.1 200 Connection established\r\n\r\n")
          if rest != "", do: :gen_tcp.send(upstream, rest)
        else
          :gen_tcp.send(upstream, [head, rest])
        end

        pipe(socket, upstream)

      {:error, _} ->
        :gen_tcp.send(socket, "HTTP/1.1 502 Bad Gateway\r\ncontent-length: 0\r\n\r\n")
        :gen_tcp.close(socket)
    end
  end

  defp parse_target(line) do
    [method, target | _] = String.split(line, " ")

    port =
      if method == "CONNECT" do
        target |> String.split(":") |> List.last() |> String.to_integer()
      else
        URI.parse(target).port
      end

    {method, port}
  end

  defp pipe(a, b) do
    :ok = :inet.setopts(a, active: :once)
    :ok = :inet.setopts(b, active: :once)
    pipe_loop(a, b)
  end

  defp pipe_loop(a, b) do
    receive do
      {:tcp, from, data} ->
        to = if from == a, do: b, else: a
        :gen_tcp.send(to, data)
        :inet.setopts(from, active: :once)
        pipe_loop(a, b)

      {:tcp_closed, _} ->
        :gen_tcp.close(a)
        :gen_tcp.close(b)

      {:tcp_error, _, _} ->
        :gen_tcp.close(a)
        :gen_tcp.close(b)
    end
  end
end
