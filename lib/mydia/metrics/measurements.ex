defmodule Mydia.Metrics.Measurements do
  @moduledoc """
  Poller callbacks for `Mydia.Metrics.Supervisor`. Each emits
  `[:mydia, :metrics, ...]` events that `Mydia.Metrics.Definitions` turns into
  gauges.
  """

  def vm, do: :ok
  def streaming, do: :ok
  def build_info, do: :ok
  def library, do: :ok
  def downloads, do: :ok
  def download_clients, do: :ok
  def oban, do: :ok
end
