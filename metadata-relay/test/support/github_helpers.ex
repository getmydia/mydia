defmodule MetadataRelay.Test.GitHubHelpers do
  @moduledoc """
  Test helpers for the GitHub OAuth and REST clients.
  """

  @config_key MetadataRelay.GitHub

  @doc """
  Installs a Req adapter for GitHub calls, with retries disabled for speed.
  """
  def set_github_adapter(adapter) do
    wrapped = fn request ->
      request = %{request | options: Map.put(request.options, :retry, false)}
      adapter.(request)
    end

    Application.put_env(:metadata_relay, :github_http_adapter, wrapped)
  end

  def clear_github_adapter do
    Application.delete_env(:metadata_relay, :github_http_adapter)
  end

  @doc """
  Sets GitHub config and returns the previous value so `on_exit` can restore it.
  """
  def put_github_config(opts) do
    previous = Application.get_env(:metadata_relay, @config_key)
    Application.put_env(:metadata_relay, @config_key, opts)
    previous
  end

  def restore_github_config(nil), do: Application.delete_env(:metadata_relay, @config_key)

  def restore_github_config(previous),
    do: Application.put_env(:metadata_relay, @config_key, previous)
end
