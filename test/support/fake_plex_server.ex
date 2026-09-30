defmodule Mydia.FakePlexServer do
  @moduledoc """
  A Plex Media Server fake for the plex plugin integration tests.

  Bypass cannot register or match Plex's `/:/scrobble`-style paths (Plug reads
  ":" as a route parameter marker), so this serves literal request paths from a
  Bandit listener. Handlers are registered per `{method, path}`, ignore the
  query string, and receive the conn with query params fetched. An unregistered
  path answers 404. Unlike `Bypass.expect_once/4`, nothing verifies call counts
  at exit: tests assert on messages their handlers send.
  """

  @behaviour Plug

  defstruct [:pid, :port, :routes]

  @type t :: %__MODULE__{pid: pid(), port: :inet.port_number(), routes: pid()}

  @spec open() :: t()
  def open do
    {:ok, routes} = Agent.start_link(fn -> %{} end)
    {:ok, pid} = Bandit.start_link(plug: {__MODULE__, routes}, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    %__MODULE__{pid: pid, port: port, routes: routes}
  end

  @spec stub(t(), String.t(), String.t(), (Plug.Conn.t() -> Plug.Conn.t())) :: :ok
  def stub(%__MODULE__{routes: routes}, method, path, fun) when is_function(fun, 1) do
    Agent.update(routes, &Map.put(&1, {method, path}, fun))
  end

  @doc "Stops listening, so every later request is refused at connect."
  @spec down(t()) :: :ok
  def down(%__MODULE__{pid: pid}), do: ThousandIsland.stop(pid)

  @impl Plug
  def init(routes), do: routes

  @impl Plug
  def call(conn, routes) do
    conn = Plug.Conn.fetch_query_params(conn)

    case Agent.get(routes, &Map.get(&1, {conn.method, conn.request_path})) do
      nil -> Plug.Conn.resp(conn, 404, "")
      fun -> fun.(conn)
    end
  end
end
