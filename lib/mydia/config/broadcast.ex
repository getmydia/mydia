defmodule Mydia.Config.Broadcast do
  @moduledoc """
  Announces a reloaded runtime config on PubSub.

  `Mydia.Config.Loader.reload/1` calls `reloaded/2` after it stores a new
  config; subscribers to `topic/0` receive `{:runtime_config_reloaded, config}`.
  """

  @topic "config:runtime"

  @doc "PubSub topic carrying `{:runtime_config_reloaded, config}` after each reload."
  @spec topic() :: String.t()
  def topic, do: @topic

  # Bootstrap reloads during application start, before the PubSub child is up.
  # Nobody can be subscribed then, so skipping is correct. Phoenix.PubSub
  # registers a Registry under its own name, so whereis tells us.
  @doc "Broadcasts `config` on `topic/0` when the PubSub named `pubsub` is running."
  @spec reloaded(atom(), struct()) :: :ok
  def reloaded(pubsub, config) do
    if Process.whereis(pubsub) do
      Phoenix.PubSub.broadcast(pubsub, @topic, {:runtime_config_reloaded, config})
    end

    :ok
  end
end
