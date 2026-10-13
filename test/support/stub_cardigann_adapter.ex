defmodule Mydia.Indexers.StubCardigannAdapter do
  @moduledoc """
  Stands in for the adapter registered under `:cardigann`. `search/3` reports
  `{query, config.id}` to the pid in `:stub_cardigann_pid` and answers
  `:stub_cardigann_search`.
  """

  def search(config, query, _opts) do
    if microseconds = Application.get_env(:mydia, :stub_cardigann_network_us),
      do: Mydia.Indexers.SearchStats.Network.add(microseconds)

    if pid = Application.get_env(:mydia, :stub_cardigann_pid),
      do: send(pid, {:stub_cardigann_search, query, config.id})

    Application.get_env(:mydia, :stub_cardigann_search, {:ok, []})
  end
end
