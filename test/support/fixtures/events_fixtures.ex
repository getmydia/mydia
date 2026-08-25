defmodule Mydia.EventsFixtures do
  @moduledoc """
  Test helpers for building events that match what the application records.
  """

  # The category an event type is actually recorded under by the `Mydia.Events`
  # writer functions. It is not the type's namespace: `media_item.*` is recorded
  # as "media" and `job.*` as "system", so deriving it from the type would
  # produce fixtures no code path ever writes.
  @category_by_namespace %{
    "download" => "downloads",
    "job" => "system",
    "media_file" => "media",
    "media_item" => "media",
    "playback" => "playback",
    "plugin" => "plugin",
    "search" => "search"
  }

  @doc """
  The category the application records the given event type under.

  Raises when a namespace has no mapping, so a new event namespace fails loudly
  here rather than producing fixtures that do not match production writes.
  """
  def category_for_type(type) when is_binary(type) do
    [namespace, _action] = String.split(type, ".")

    Map.get_lazy(@category_by_namespace, namespace, fn ->
      raise ArgumentError,
            "no category mapped for event namespace #{inspect(namespace)}; " <>
              "add it to Mydia.EventsFixtures"
    end)
  end
end
