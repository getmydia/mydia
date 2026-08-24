defmodule MetadataRelay.ReqAdapter do
  @moduledoc """
  Bridges the relay's configurable HTTP adapter functions to Req's module
  adapter interface.

  The function remains private to the request so each client can keep its
  existing test-injection boundary without registering global adapter modules.
  """

  @adapter_key :metadata_relay_http_adapter

  def attach(request, nil), do: request

  def attach(%Req.Request{} = request, adapter) when is_function(adapter, 1) do
    request = Req.Request.put_private(request, @adapter_key, adapter)
    %{request | adapter: __MODULE__}
  end

  def run(%Req.Request{} = request) do
    request
    |> Req.Request.get_private(@adapter_key)
    |> then(& &1.(request))
  end
end
