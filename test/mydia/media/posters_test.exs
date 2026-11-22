defmodule Mydia.Media.PostersTest do
  # Changes the global :generated_media_path env, so it cannot run async.
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures

  alias Mydia.Accounts.Scope
  alias Mydia.Media
  alias Mydia.Media.MediaItem
  alias Mydia.Media.PosterStore
  alias Mydia.Media.Posters
  alias Mydia.Repo

  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0::64>>
  @jpg <<0xFF, 0xD8, 0xFF, 0xE0, 0::64>>

  setup do
    dir = Path.join(System.tmp_dir!(), "posters_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = Application.fetch_env(:mydia, :generated_media_path)
    Application.put_env(:mydia, :generated_media_path, dir)
    File.mkdir_p!(PosterStore.storage_dir())

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:mydia, :generated_media_path, value)
        :error -> Application.delete_env(:mydia, :generated_media_path)
      end

      File.rm_rf!(dir)
    end)

    :ok
  end

  defp disk_path(url), do: Path.join(PosterStore.storage_dir(), Path.basename(url))

  describe "effective_path/1" do
    test "the override wins over metadata" do
      item = media_item_fixture(%{metadata: %{poster_path: "/provider.jpg"}})

      {:ok, item} =
        item
        |> MediaItem.poster_override_changeset(%{poster_override: "/chosen.jpg"})
        |> Repo.update()

      assert Posters.effective_path(item) == "/chosen.jpg"
    end

    test "nil override falls back to metadata.poster_path" do
      item = media_item_fixture(%{metadata: %{poster_path: "/provider.jpg"}})
      assert Posters.effective_path(item) == "/provider.jpg"
    end

    test "an empty override falls back to metadata" do
      item = media_item_fixture(%{metadata: %{poster_path: "/provider.jpg"}})
      assert Posters.effective_path(%{item | poster_override: ""}) == "/provider.jpg"
    end

    test "no override and no metadata is nil" do
      assert Posters.effective_path(%MediaItem{poster_override: nil, metadata: nil}) == nil
    end
  end

  describe "poster_override_changeset/2" do
    test "changeset/2 never casts poster_override" do
      item = media_item_fixture(%{})
      changeset = MediaItem.changeset(item, %{poster_override: "/x.jpg"})
      refute Map.has_key?(changeset.changes, :poster_override)
    end
  end

  describe "writes" do
    test "upload stores a hosted override; replacing deletes the previous file" do
      item = media_item_fixture()
      {:ok, item} = Posters.set_uploaded_poster(Scope.unrestricted(), item, @png)
      first = item.poster_override
      assert PosterStore.hosted?(first)
      {:ok, item} = Posters.set_uploaded_poster(Scope.unrestricted(), item, @jpg)
      refute File.exists?(disk_path(first))
      assert Posters.effective_path(item) == item.poster_override
    end

    test "a non-image upload is rejected and nothing is written" do
      item = media_item_fixture()

      assert {:error, :unsupported_format} =
               Posters.set_uploaded_poster(Scope.unrestricted(), item, "<html>")

      assert Repo.reload!(item).poster_override == nil
      assert File.ls!(PosterStore.storage_dir()) == []
    end

    test "provider poster replaces a hosted one and deletes its file" do
      item = media_item_fixture()
      {:ok, item} = Posters.set_uploaded_poster(Scope.unrestricted(), item, @png)
      hosted = item.poster_override
      {:ok, item} = Posters.set_provider_poster(Scope.unrestricted(), item, "/alt.jpg")
      assert item.poster_override == "/alt.jpg"
      refute File.exists?(disk_path(hosted))
    end

    test "provider poster rejects hosted-shaped paths without writing" do
      item = media_item_fixture()

      assert {:error, :invalid_poster} =
               Posters.set_provider_poster(
                 Scope.unrestricted(),
                 item,
                 "/generated/posters/#{Ecto.UUID.generate()}-deadbeef.png"
               )

      assert Repo.reload!(item).poster_override == nil
    end

    test "setting a poster records a media_item.updated event" do
      item = media_item_fixture()
      Phoenix.PubSub.subscribe(Mydia.PubSub, "events:all")
      {:ok, _} = Posters.set_provider_poster(Scope.unrestricted(), item, "/chosen.jpg")

      assert_receive {:event_created, %{type: "media_item.updated"} = event}, 1_000
      assert event.metadata["changes"]["poster_override"]["new"] == "/chosen.jpg"
    end

    test "reset clears the override and the file" do
      item = media_item_fixture(%{metadata: %{poster_path: "/provider.jpg"}})
      {:ok, item} = Posters.set_uploaded_poster(Scope.unrestricted(), item, @png)
      hosted = item.poster_override
      {:ok, item} = Posters.reset_poster(Scope.unrestricted(), item)
      assert item.poster_override == nil
      assert Posters.effective_path(item) == "/provider.jpg"
      refute File.exists?(disk_path(hosted))
    end

    test "a user who may not edit media is refused by every setter" do
      item = media_item_fixture()
      scope = Scope.for_user(Mydia.AccountsFixtures.user_fixture(%{role: "readonly"}))

      assert {:error, :unauthorized} = Posters.set_provider_poster(scope, item, "/chosen.jpg")
      assert {:error, :unauthorized} = Posters.set_uploaded_poster(scope, item, @png)
      assert {:error, :unauthorized} = Posters.reset_poster(scope, item)
      assert Repo.reload!(item).poster_override == nil
      assert File.ls!(PosterStore.storage_dir()) == []
    end

    test "an editor's scope may set a poster" do
      item = media_item_fixture()
      scope = Scope.for_user(Mydia.AccountsFixtures.user_fixture(%{role: "user"}))

      assert {:ok, %{poster_override: "/chosen.jpg"}} =
               Posters.set_provider_poster(scope, item, "/chosen.jpg")
    end

    test "re-uploading identical bytes keeps the file" do
      item = media_item_fixture()
      {:ok, item} = Posters.set_uploaded_poster(Scope.unrestricted(), item, @png)
      {:ok, item} = Posters.set_uploaded_poster(Scope.unrestricted(), item, @png)
      assert File.exists?(disk_path(item.poster_override))
    end

    test "a metadata refresh keeps the override" do
      item = media_item_fixture(%{metadata: %{poster_path: "/old.jpg"}})
      {:ok, item} = Posters.set_provider_poster(Scope.unrestricted(), item, "/chosen.jpg")

      {:ok, item} =
        Media.update_media_item(Scope.unrestricted(), item, %{
          metadata: %{poster_path: "/new.jpg"}
        })

      assert item.poster_override == "/chosen.jpg"
      assert Posters.effective_path(item) == "/chosen.jpg"
    end

    test "deleting the item removes its hosted poster" do
      item = media_item_fixture()
      {:ok, item} = Posters.set_uploaded_poster(Scope.unrestricted(), item, @png)
      {:ok, _, _} = Media.delete_media_item(Scope.unrestricted(), item)
      refute File.exists?(disk_path(item.poster_override))
    end

    test "bulk deleting items removes their hosted posters" do
      item = media_item_fixture()
      {:ok, item} = Posters.set_uploaded_poster(Scope.unrestricted(), item, @png)
      {:ok, 1, _} = Media.delete_media_items(Scope.unrestricted(), [item.id])
      refute File.exists?(disk_path(item.poster_override))
    end
  end
end
