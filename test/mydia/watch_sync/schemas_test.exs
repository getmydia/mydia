defmodule Mydia.WatchSync.SchemasTest do
  use Mydia.DataCase, async: true

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
end
