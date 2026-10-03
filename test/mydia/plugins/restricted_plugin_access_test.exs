defmodule Mydia.Plugins.RestrictedPluginAccessTest do
  use Mydia.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.MetadataCacheHelpers

  alias Mydia.Media.MediaItem
  alias Mydia.Media.RemoteSignals
  alias Mydia.Plugins.Error
  alias Mydia.Plugins.HostFunctions
  alias Mydia.Plugins.PageReads
  alias Mydia.Plugins.PageWrites
  alias Mydia.Plugins.Plugin

  defp with_age(item, age) do
    Repo.update_all(from(m in MediaItem, where: m.id == ^item.id), set: [content_rating_age: age])
    item
  end

  setup do
    user = restricted_user_fixture(%{max_content_age: 12})
    hidden = [title: "Iron Chorus"] |> Map.new() |> media_item_fixture() |> with_age(17)
    visible = [title: "Paper Boats"] |> Map.new() |> media_item_fixture() |> with_age(8)

    plugin = %Plugin{
      slug: "helper",
      name: "Helper",
      enabled: true,
      granted_capabilities: %{"data:read" => ["media_item"], "data:search" => []}
    }

    ctx = %{
      handler: :on_http,
      acting_user_id: user.id,
      role: user.role,
      session_id: "s",
      invocation_id: "i",
      slug: "helper"
    }

    %{user: user, hidden: hidden, visible: visible, ctx: ctx, plugin: plugin}
  end

  test "data_read hides an out-of-bounds item from a restricted user", c do
    assert {:error, %Error{type: :not_found}} =
             HostFunctions.data_read(
               c.plugin,
               %{"resource" => "media_item", "id" => c.hidden.id},
               c.ctx
             )

    assert {:ok, %{"id" => _}} =
             HostFunctions.data_read(
               c.plugin,
               %{"resource" => "media_item", "id" => c.visible.id},
               c.ctx
             )
  end

  test "data_read without a user context still reads as the system", c do
    assert {:ok, _} =
             HostFunctions.data_read(c.plugin, %{"resource" => "media_item", "id" => c.hidden.id})
  end

  test "catalog search drops titles over the limit", c do
    ok = unique_provider_id()
    blocked = unique_provider_id()

    warm_movie_search_cache("chorus", [], [
      %{"id" => ok, "title" => "Chorus Kites"},
      %{"id" => blocked, "title" => "Chorus Knives"}
    ])

    warm_remote_signals({:tmdb, ok}, :movie, %RemoteSignals{
      content_rating: "PG",
      age: 8,
      category: "movie"
    })

    warm_remote_signals({:tmdb, blocked}, :movie, %RemoteSignals{
      content_rating: "R",
      age: 17,
      category: "movie"
    })

    req = %{kind: :catalog, query: "chorus", "media-type": {:some, "movie"}, limit: :none}

    assert {:ok, hits} = PageReads.search(c.plugin, c.ctx, req)
    assert Enum.map(hits, & &1.title) == ["Chorus Kites"]
  end

  test "favorite_add refuses a hidden id like a missing one", c do
    assert {:error, hidden_error} =
             PageWrites.execute("favorite_add", %{"media_item_id" => c.hidden.id}, c.user, nil)

    assert {:error, missing_error} =
             PageWrites.execute(
               "favorite_add",
               %{"media_item_id" => Ecto.UUID.generate()},
               c.user,
               nil
             )

    assert hidden_error == missing_error

    assert {:ok, %{"status" => "changed"}, _} =
             PageWrites.execute("favorite_add", %{"media_item_id" => c.visible.id}, c.user, nil)
  end

  test "collection_add_items skips hidden ids", c do
    {:ok, collection} =
      Mydia.Collections.create_collection(c.user, %{"name" => "Shelf", "type" => "manual"})

    args = %{"id" => collection.id, "media_item_ids" => [c.hidden.id, c.visible.id]}

    assert {:ok, %{"added" => 1}, %{"media_item_ids" => [id]}} =
             PageWrites.execute("collection_add_items", args, c.user, nil)

    assert id == c.visible.id
  end
end
