defmodule Mydia.Indexers.Cardigann.RequestError do
  @moduledoc """
  Maps a failed Cardigann HTTP request to an indexer error.

  A failure that happened on the way through the configured proxy is named
  after it; every other failure keeps its existing message.
  """

  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Net.Proxy

  @spec from_reason(term(), String.t()) :: Error.t()
  def from_reason(reason, url) do
    proxy_msg = if is_exception(reason), do: Proxy.describe_error(reason, URI.parse(url).host)

    case {proxy_msg, reason} do
      {msg, _} when is_binary(msg) ->
        Error.connection_failed(msg)

      {nil, %Req.TransportError{reason: reason}} ->
        Error.connection_failed("Connection failed: #{inspect(reason)}")

      {nil, reason} ->
        Error.search_failed("Request failed: #{inspect(reason)}")
    end
  end
end
