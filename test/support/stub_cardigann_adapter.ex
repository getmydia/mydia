defmodule Mydia.Indexers.StubCardigannAdapter do
  @moduledoc """
  Stands in for the adapter registered under `:cardigann`. `search/3` reports
  `{query, config.id}` to the pid in `:stub_cardigann_pid` and answers
  `:stub_cardigann_search`. It also sends that pid
  `{:stub_cardigann_opts, opts}`.
  """

  def search(config, query, opts) do
    if microseconds = Application.get_env(:mydia, :stub_cardigann_network_us),
      do: Mydia.Indexers.SearchStats.Network.add(microseconds)

    if pid = Application.get_env(:mydia, :stub_cardigann_pid) do
      send(pid, {:stub_cardigann_search, query, config.id})
      send(pid, {:stub_cardigann_opts, opts})
    end

    Application.get_env(:mydia, :stub_cardigann_search, {:ok, []})
  end
end
