defmodule Mydia.WatchSync.SchemasTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures

  alias Mydia.WatchSync.{Mapping, State}

  test "a mapping requires exactly one of media_item_id or episode_id" do
    both =
      Mapping.changeset(%Mapping{}, %{
        provider: "plex",
        provider_instance_id: "i",
        remote_id: "1",
        media_item_id: Ecto.UUID.generate(),
        episode_id: Ecto.UUID.generate()
      })

    refute both.valid?

    neither =
      Mapping.changeset(%Mapping{}, %{provider: "plex", provider_instance_id: "i", remote_id: "1"})

    refute neither.valid?
  end

  test "a state row requires exactly one parent" do
    changeset =
      State.changeset(%State{}, %{
        user_id: Ecto.UUID.generate(),
        provider: "plex",
        provider_instance_id: "i",
        synced_watched: true
      })

    refute changeset.valid?
  end

  test "a local item can map to several remote copies, each only once" do
    movie = media_item_fixture()
    attrs = %{provider: "jellyfin", provider_instance_id: "i", media_item_id: movie.id}

    insert = fn remote_id ->
      %Mapping{}
      |> Mapping.changeset(Map.put(attrs, :remote_id, remote_id))
      |> Repo.insert()
    end

    assert {:ok, _} = insert.("copy-a")
    assert {:ok, _} = insert.("copy-b")
    assert {:error, changeset} = insert.("copy-a")
    assert {"already mapped to this remote item", _} = changeset.errors[:remote_id]
  end

  test "an episode can map to several remote copies, each only once" do
    {:ok, show} =
      Mydia.Media.create_media_item(
        Mydia.Accounts.Scope.unrestricted(),
        %{title: "Copy Index Show", type: "tv_show", tvdb_id: 900_001},
        skip_episode_refresh: true
      )

    {:ok, episode} =
      Mydia.Media.create_episode(%{
        media_item_id: show.id,
        season_number: 1,
        episode_number: 1,
        title: "Pilot"
      })

    attrs = %{provider: "jellyfin", provider_instance_id: "i", episode_id: episode.id}

    insert = fn remote_id ->
      %Mapping{}
      |> Mapping.changeset(Map.put(attrs, :remote_id, remote_id))
      |> Repo.insert()
    end

    assert {:ok, _} = insert.("copy-a")
    assert {:ok, _} = insert.("copy-b")
    assert {:error, changeset} = insert.("copy-a")
    assert {"already mapped to this remote item", _} = changeset.errors[:remote_id]
  end
end
