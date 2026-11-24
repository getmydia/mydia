defmodule Mydia.Plugins.TestEvent do
  @moduledoc """
  Builds the synthetic event the admin Test button fires at a plugin
  (`Mydia.Plugins.test_invoke/2`).

  Media request types get request-shaped metadata (requester, notes, approver,
  rejection reason) so a notifier can render them; every other type gets a
  media item.
  """

  @doc "A synthetic event map of `event_type`, marked `\"test\" => true`."
  @spec build(String.t()) :: map()
  def build("media_request." <> _ = event_type) do
    event_type
    |> base("requests", "media_request")
    |> Map.update!(
      :metadata,
      &Map.merge(&1, %{
        "requester" => "Test User",
        "requester_notes" => "Sent from the Test button",
        "approved_by" => "Admin",
        "rejection_reason" => "Test rejection"
      })
    )
  end

  def build(event_type), do: base(event_type, "media", "media_item")

  defp base(event_type, category, resource_type) do
    %{
      type: event_type,
      category: category,
      severity: :info,
      actor_type: :system,
      actor_id: "plugin_test",
      resource_type: resource_type,
      resource_id: Ecto.UUID.generate(),
      metadata: %{
        "title" => "Test Movie",
        "media_type" => "movie",
        "year" => 2026,
        "test" => true
      }
    }
  end
end
