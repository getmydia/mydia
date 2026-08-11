defmodule Mydia.MediaServer.Client do
  @moduledoc """
  Behaviour for media server adapters (Plex, Jellyfin).
  """

  alias Mydia.MediaServer.Error
  alias Mydia.Settings.MediaServerConfig

  @doc """
  Tests the connection to the media server.
  """
  @callback test_connection(config :: MediaServerConfig.t()) :: :ok | {:error, Error.t()}

  @doc """
  Triggers a library scan/update on the media server.

  Options may include:
  - `path`: Specific path to scan (if supported)
  """
  @callback update_library(config :: MediaServerConfig.t(), opts :: keyword()) ::
              :ok | {:error, Error.t()}

  @doc """
  Returns the adapter module for the given configuration.
  """
  def adapter_for(%MediaServerConfig{type: :plex}), do: Mydia.MediaServer.Client.Plex
  def adapter_for(%MediaServerConfig{type: :jellyfin}), do: Mydia.MediaServer.Client.Jellyfin
end
