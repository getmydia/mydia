defmodule Mydia.Metrics.Tags do
  @moduledoc """
  Tag values for the event-driven metrics in `Mydia.Metrics.Definitions`.

  Same contract as `Mydia.Perf.Keys`: none of these may raise, because
  `:telemetry` detaches a handler that raises and Peep attaches one handler per
  event. Anything unrecognised becomes `"unknown"`. Every value comes from a
  bounded set: route patterns, HTTP methods, status classes, queue and worker
  module names, indexer names, engines and outcomes.
  """

  alias Mydia.Perf.Keys

  @unknown "unknown"
  @unscraped_routes ["/metrics", "/health"]

  @doc "Router dispatch: route pattern, method and status class."
  @spec http(term()) :: %{route: String.t(), method: String.t(), status_class: String.t()}
  def http(metadata) do
    guard(%{route: @unknown, method: @unknown, status_class: @unknown}, fn ->
      %{conn: %Plug.Conn{method: method, status: status}} = metadata
      Map.merge(Keys.route(metadata), %{method: method, status_class: status_class(status)})
    end)
  end

  @doc "Whether a router dispatch counts: scrapes and health checks do not."
  @spec keep_http?(term()) :: boolean()
  def keep_http?(%{route: route}), do: route not in @unscraped_routes
  def keep_http?(_metadata), do: true

  @doc "Oban job events: the queue and the worker."
  @spec oban_job(term()) :: %{queue: String.t(), worker: String.t()}
  def oban_job(metadata) do
    guard(%{queue: @unknown, worker: @unknown}, fn ->
      %{job: %Oban.Job{queue: queue, worker: worker}} = metadata
      %{queue: to_string(queue), worker: to_string(worker)}
    end)
  end

  @doc "Indexer calls: name, engine (`none` outside Cardigann), kind and outcome."
  @spec indexer_search(term()) :: %{
          indexer_name: String.t(),
          engine: String.t(),
          kind: String.t(),
          outcome: String.t()
        }
  def indexer_search(metadata) do
    guard(%{indexer_name: @unknown, engine: @unknown, kind: @unknown, outcome: @unknown}, fn ->
      %{indexer_name: name, kind: kind, outcome: outcome} = metadata

      %{
        indexer_name: to_string(name),
        engine: to_string(Map.get(metadata, :engine) || "none"),
        kind: to_string(kind),
        outcome: to_string(outcome)
      }
    end)
  end

  defp status_class(status) when is_integer(status) and status in 100..599,
    do: "#{div(status, 100)}xx"

  defp status_class(_status), do: @unknown

  defp guard(fallback, fun) do
    fun.()
  rescue
    _exception -> fallback
  end
end
