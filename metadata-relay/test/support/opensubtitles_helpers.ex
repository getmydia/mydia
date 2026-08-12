defmodule MetadataRelay.Test.OpenSubtitlesHelpers.StubAuth do
  @moduledoc false

  # Minimal GenServer registered under the real Auth module's name, so
  # MetadataRelay.OpenSubtitles.Auth.get_token/0 succeeds in tests without
  # ever performing the real OpenSubtitles login handshake
  # (MetadataRelay.OpenSubtitles.Auth.authenticate/0 is a raw, unmockable
  # Req.post to the live login endpoint).

  use GenServer

  def start_link(token) do
    GenServer.start_link(__MODULE__, token, name: MetadataRelay.OpenSubtitles.Auth)
  end

  @impl true
  def init(token), do: {:ok, token}

  @impl true
  def handle_call(:get_token, _from, token), do: {:reply, {:ok, token}, token}
end

defmodule MetadataRelay.Test.OpenSubtitlesHelpers do
  @moduledoc """
  Test helpers for OpenSubtitles client/handler testing.

  Provides utilities for creating mock HTTP adapters for
  `MetadataRelay.OpenSubtitles.Client` (mirrors
  `MetadataRelay.Test.TMDBHelpers`), plus a stub Auth process so tests never
  perform the real OpenSubtitles login handshake.
  """

  alias MetadataRelay.Test.OpenSubtitlesHelpers.StubAuth

  @doc """
  Creates a mock HTTP adapter that returns different responses based on URL.

  ## Examples

      adapter = mock_adapter_with_routes(%{
        "/subtitles" => {200, %{"data" => [...]}}
      })
  """
  def mock_adapter_with_routes(routes) do
    fn request ->
      url = request.url |> URI.to_string()

      {status, body} =
        Enum.find_value(routes, {404, %{"error" => "Not found"}}, fn {pattern, response} ->
          if String.contains?(url, pattern), do: response
        end)

      {request, Req.Response.new(status: status, body: body)}
    end
  end

  @doc """
  Sets up the OpenSubtitles HTTP adapter for testing.

  Should be called in test setup and cleaned up with
  `clear_opensubtitles_adapter/0`.
  """
  def set_opensubtitles_adapter(adapter) do
    # Wrap the adapter to also disable Req's retry mechanism for faster tests
    wrapped_adapter = fn request ->
      request = %{request | options: Map.put(request.options, :retry, false)}
      adapter.(request)
    end

    Application.put_env(:metadata_relay, :opensubtitles_http_adapter, wrapped_adapter)
  end

  @doc """
  Clears the OpenSubtitles HTTP adapter after testing.
  """
  def clear_opensubtitles_adapter do
    Application.delete_env(:metadata_relay, :opensubtitles_http_adapter)
  end

  @doc """
  Starts a stub Auth process so `MetadataRelay.OpenSubtitles.Client.new/0`
  can obtain a token without the real Auth GenServer or a live login call.

  Returns the stub process's pid; stop it in `on_exit` with
  `GenServer.stop/1`.
  """
  def start_stub_auth(token \\ "stub-token") do
    {:ok, pid} = StubAuth.start_link(token)
    pid
  end
end
