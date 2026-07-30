defmodule MetadataRelay.Test.TMDBHelpers do
  @moduledoc """
  Test helpers for TMDB module testing.

  Provides utilities for creating mock HTTP adapters for the TMDB client.
  """

  @doc """
  Creates a mock HTTP adapter that returns different responses based on URL.

  ## Examples

      adapter = mock_adapter_with_routes(%{
        "/3/collection/10" => {200, %{"id" => 10, "name" => "Star Wars Collection"}}
      })
  """
  def mock_adapter_with_routes(routes) do
    fn request ->
      url = request.url |> URI.to_string()

      # Find matching route
      {status, body} =
        Enum.find_value(routes, {404, %{"error" => "Not found"}}, fn {pattern, response} ->
          if String.contains?(url, pattern), do: response
        end)

      {request, Req.Response.new(status: status, body: body)}
    end
  end

  @doc """
  Sets up the TMDB HTTP adapter for testing.

  Should be called in test setup and cleaned up with `clear_tmdb_adapter/0`.
  """
  def set_tmdb_adapter(adapter) do
    # Wrap the adapter to also disable Req's retry mechanism for faster tests
    wrapped_adapter = fn request ->
      # Remove retry step from request options to speed up tests
      request = %{request | options: Map.put(request.options, :retry, false)}
      adapter.(request)
    end

    Application.put_env(:metadata_relay, :tmdb_http_adapter, wrapped_adapter)
  end

  @doc """
  Clears the TMDB HTTP adapter after testing.
  """
  def clear_tmdb_adapter do
    Application.delete_env(:metadata_relay, :tmdb_http_adapter)
  end
end
