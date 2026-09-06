defmodule MydiaWeb.Schema.Publish do
  @moduledoc """
  Best-effort wrapper around `Absinthe.Subscription.publish/3`.

  `Absinthe.Subscription` starts after `MydiaWeb.Endpoint` in the supervision
  tree (see `Mydia.Application`), since it needs the endpoint's pubsub to
  exist first. That leaves a boot window where the endpoint accepts requests
  before the subscription registry is up, and `Absinthe.Subscription.publish/3`
  raises `ArgumentError` in that window. Publishing is telemetry for live
  subscribers, so it must never turn an already-committed write into a
  mutation error.
  """

  require Logger

  @spec publish(Absinthe.Subscription.Pubsub.t(), term(), keyword() | String.t()) :: :ok
  def publish(pubsub, value, topic) do
    Absinthe.Subscription.publish(pubsub, value, topic)
    :ok
  rescue
    error ->
      Logger.warning(
        "Absinthe.Subscription.publish/3 failed, skipping subscription event: " <>
          Exception.message(error)
      )

      :ok
  catch
    :exit, reason ->
      Logger.warning(
        "Absinthe.Subscription.publish/3 exited, skipping subscription event: " <>
          inspect(reason)
      )

      :ok
  end
end
