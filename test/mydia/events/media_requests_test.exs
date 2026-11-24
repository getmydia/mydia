defmodule Mydia.Events.MediaRequestsTest do
  use Mydia.DataCase

  import Mydia.AccountsFixtures

  alias Mydia.Events
  alias Mydia.Events.MediaRequests
  alias Mydia.Media.MediaRequest

  defp build_request(user, attrs \\ %{}) do
    struct!(
      %MediaRequest{
        id: Ecto.UUID.generate(),
        title: "The Glass Orchard",
        year: 2031,
        media_type: "movie",
        tmdb_id: 900_001,
        requester_id: user.id,
        requester: user
      },
      attrs
    )
  end

  test "created records who asked for what" do
    user = user_fixture(%{username: "quillon", display_name: "Quill Onyx"})
    request = build_request(user, %{requester_notes: "Director's cut please"})

    assert :ok = MediaRequests.created(request)
    [event] = Events.list_events(type: "media_request.created")
    assert event.category == "requests"
    assert event.actor_type == :user and event.actor_id == user.id
    assert event.resource_type == "media_request" and event.resource_id == request.id

    assert event.metadata == %{
             "title" => "The Glass Orchard",
             "year" => 2031,
             "media_type" => "movie",
             "tmdb_id" => 900_001,
             "requester" => "Quill Onyx",
             "requester_notes" => "Director's cut please"
           }
  end

  test "requester falls back to username and nil metadata is omitted" do
    user = user_fixture(%{username: "quillon"})
    user = %{user | display_name: nil}

    assert :ok = MediaRequests.created(build_request(user))
    [event] = Events.list_events(type: "media_request.created")
    assert event.metadata["requester"] == "quillon"
    refute Map.has_key?(event.metadata, "requester_notes")
  end

  test "requester key is absent when the requester is nil or not loaded" do
    user = user_fixture()

    for requester <- [nil, %Ecto.Association.NotLoaded{}] do
      assert :ok = MediaRequests.created(build_request(user, %{requester: requester}))
    end

    events = Events.list_events(type: "media_request.created")
    assert length(events) == 2
    refute Enum.any?(events, &Map.has_key?(&1.metadata, "requester"))
  end

  test "approved attributes the approving admin" do
    user = user_fixture(%{username: "quillon", display_name: "Quill Onyx"})
    admin = user_fixture(%{username: "warden", display_name: "Warden Vale", role: "admin"})

    assert :ok = MediaRequests.approved(build_request(user), approved_by: admin)
    [event] = Events.list_events(type: "media_request.approved")
    assert event.category == "requests"
    assert event.actor_type == :user and event.actor_id == admin.id
    assert event.metadata["approved_by"] == "Warden Vale"
    assert event.metadata["auto"] == false
    assert event.metadata["requester"] == "Quill Onyx"
  end

  test "approved with auto: true is a system event" do
    user = user_fixture()

    assert :ok = MediaRequests.approved(build_request(user), auto: true)
    [event] = Events.list_events(type: "media_request.approved")
    assert event.actor_type == :system and event.actor_id == "auto_approve"
    assert event.metadata["auto"] == true
    refute Map.has_key?(event.metadata, "approved_by")
  end

  test "rejected records the rejecter and reason" do
    user = user_fixture()
    admin = user_fixture(%{username: "warden", display_name: "Warden Vale", role: "admin"})
    request = build_request(user, %{rejection_reason: "Already on the shelf"})

    assert :ok = MediaRequests.rejected(request, rejected_by: admin)
    [event] = Events.list_events(type: "media_request.rejected")
    assert event.category == "requests"
    assert event.actor_type == :user and event.actor_id == admin.id
    assert event.metadata["approved_by"] == "Warden Vale"
    assert event.metadata["rejection_reason"] == "Already on the shelf"
  end

  test "approved and rejected events carry requester_notes, omitted when nil" do
    user = user_fixture()
    admin = user_fixture(%{username: "warden", display_name: "Warden Vale", role: "admin"})
    noted = build_request(user, %{requester_notes: "Director's cut please"})

    assert :ok = MediaRequests.approved(noted, approved_by: admin)
    assert :ok = MediaRequests.rejected(noted, rejected_by: admin)
    assert :ok = MediaRequests.approved(build_request(user), auto: true)
    assert :ok = MediaRequests.rejected(build_request(user), rejected_by: admin)

    for type <- ["media_request.approved", "media_request.rejected"] do
      events = Events.list_events(type: type)

      assert Enum.count(events, &(&1.metadata["requester_notes"] == "Director's cut please")) ==
               1

      assert Enum.count(events, &(not Map.has_key?(&1.metadata, "requester_notes"))) == 1
    end
  end
end
