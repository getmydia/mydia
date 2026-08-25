defmodule Mydia.Events.VisibilityTest do
  use Mydia.DataCase, async: true

  import Ecto.Query, only: [select: 3]
  import Mydia.AccountsFixtures

  alias Mydia.Events
  alias Mydia.Events.Event
  alias Mydia.Events.Visibility
  alias Mydia.Events.Visibility.Policy
  alias Mydia.Repo

  describe "policy_for/1" do
    test "admin, user and readonly are unrestricted" do
      for role <- ~w(admin user readonly) do
        assert Visibility.policy_for(user_fixture(%{role: role})) == :unrestricted
      end
    end

    test "a guest gets the guest policy" do
      assert %Policy{types: types, own_types: own_types} =
               Visibility.policy_for(user_fixture(%{role: "guest"}))

      assert types == ["media_item.added", "media_item.removed"]

      assert own_types == [
               "playback.started",
               "playback.finished",
               "playback.unwatched"
             ]
    end

    test "no viewer is denied everything" do
      assert Visibility.policy_for(nil) == :none
    end
  end

  describe "visible?/2" do
    setup do
      %{guest: user_fixture(%{role: "guest"}), other: user_fixture(%{role: "guest"})}
    end

    test "an allowed shared type is visible whoever caused it", %{guest: guest, other: other} do
      assert Visibility.visible?(event(:system, "media_context", "media_item.added"), guest)
      assert Visibility.visible?(event(:user, other.id, "media_item.removed"), guest)
    end

    test "a type outside the policy is hidden", %{guest: guest} do
      refute Visibility.visible?(event(:system, "download_monitor", "download.completed"), guest)
      refute Visibility.visible?(event(:system, "media_context", "media_item.updated"), guest)
      refute Visibility.visible?(event(:system, "media_context", "media_file.imported"), guest)
    end

    test "an own_type is visible only for the viewer's own events", %{
      guest: guest,
      other: other
    } do
      assert Visibility.visible?(event(:user, guest.id, "playback.started"), guest)
      refute Visibility.visible?(event(:user, other.id, "playback.started"), guest)
    end

    test "an own_type from a non-user actor is hidden", %{guest: guest} do
      refute Visibility.visible?(event(:system, guest.id, "playback.started"), guest)
    end

    test "progressed and paused are hidden even for the viewer's own account", %{guest: guest} do
      refute Visibility.visible?(event(:user, guest.id, "playback.progressed"), guest)
      refute Visibility.visible?(event(:user, guest.id, "playback.paused"), guest)
    end

    test "an unrestricted viewer sees everything", %{guest: guest} do
      admin = admin_user_fixture()

      assert Visibility.visible?(event(:system, "download_monitor", "download.failed"), admin)
      assert Visibility.visible?(event(:user, guest.id, "playback.progressed"), admin)
    end

    test "no viewer sees nothing" do
      refute Visibility.visible?(event(:system, "media_context", "media_item.added"), nil)
    end

    defp event(actor_type, actor_id, type) do
      %Event{type: type, actor_type: actor_type, actor_id: actor_id}
    end
  end

  describe "scope/2" do
    test "an unrestricted viewer's query is untouched" do
      insert_event("download.completed", :system, "download_monitor")

      assert [_] = scoped_types(admin_user_fixture())
    end

    test "a guest's query returns only allowed rows" do
      guest = user_fixture(%{role: "guest"})
      other = user_fixture(%{role: "guest"})

      insert_event("media_item.added", :system, "media_context")
      insert_event("download.completed", :system, "download_monitor")
      insert_event("playback.started", :user, guest.id)
      insert_event("playback.started", :user, other.id)
      insert_event("playback.progressed", :user, guest.id)

      assert scoped_types(guest) == ["media_item.added", "playback.started"]
    end

    test "no viewer returns no rows" do
      insert_event("media_item.added", :system, "media_context")

      assert scoped_types(nil) == []
    end

    defp insert_event(type, actor_type, actor_id) do
      {:ok, event} =
        Events.create_event(%{
          category: "media",
          type: type,
          actor_type: actor_type,
          actor_id: actor_id,
          metadata: %{"title" => "Fixture Title"}
        })

      event
    end

    defp scoped_types(user) do
      Event
      |> Visibility.scope(user)
      |> select([e], e.type)
      |> Repo.all()
      |> Enum.sort()
    end
  end
end
