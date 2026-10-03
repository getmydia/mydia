defmodule MydiaWeb.MediaLive.Show.FileEventsTest do
  @moduledoc """
  Tests for the media-file delete handlers in `MydiaWeb.MediaLive.Show.FileEvents`.

  The delete branches are socket transforms over context calls, exercised by
  calling the handler directly with a constructed socket so the Ecto sandbox
  stays in the test process (the same strategy as `ReidentifyEventsTest`).
  """
  use MydiaWeb.ConnCase, async: false

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures
  import Mydia.AccountsFixtures

  alias Mydia.Accounts.Scope
  alias MydiaWeb.MediaLive.Show.FileEvents
  alias Mydia.Library
  alias Mydia.Library.MediaFile

  defp stub_socket(extra_assigns) do
    base = %{__changed__: %{}, flash: %{}}

    %Phoenix.LiveView.Socket{
      assigns: Map.merge(base, extra_assigns),
      private: %{live_temp: %{}}
    }
  end

  defp flash_text(%Phoenix.LiveView.Socket{assigns: %{flash: f}}, kind),
    do: f[to_string(kind)]

  setup do
    tmp = Path.join(System.tmp_dir!(), "mydia_fe_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    %{
      library_path: library_path_fixture(%{path: tmp, type: "movies"}),
      media_item: media_item_fixture(%{type: "movie"}),
      user: user_fixture()
    }
  end

  defp file_on_disk(lp, media_item, rel, contents) do
    File.write!(Path.join(lp.path, rel), contents)

    {:ok, file} =
      Library.create_scanned_media_file(%{
        relative_path: rel,
        library_path_id: lp.id,
        media_item_id: media_item.id,
        size: byte_size(contents)
      })

    Mydia.Repo.preload(file, :library_path)
  end

  defp delete_socket(ctx, file, mode) do
    stub_socket(%{
      current_user: ctx.user,
      current_scope: Scope.for_user(ctx.user),
      media_item: ctx.media_item,
      file_to_delete: file,
      file_delete_mode: mode
    })
  end

  test "permanent mode deletes the file and flashes info", ctx do
    file = file_on_disk(ctx.library_path, ctx.media_item, "movie.mkv", "data")
    abs = MediaFile.absolute_path(file)

    {:noreply, socket} = FileEvents.delete_media_file(%{}, delete_socket(ctx, file, :permanent))

    refute File.exists?(abs)
    refute Mydia.Repo.get(MediaFile, file.id)
    assert flash_text(socket, :info) =~ "including the file on disk"
  end

  test "library_only mode keeps the file and flashes info", ctx do
    file = file_on_disk(ctx.library_path, ctx.media_item, "keep.mkv", "data")
    abs = MediaFile.absolute_path(file)

    {:noreply, socket} =
      FileEvents.delete_media_file(%{}, delete_socket(ctx, file, :library_only))

    assert File.exists?(abs)
    refute Mydia.Repo.get(MediaFile, file.id)
    assert flash_text(socket, :info) =~ "kept on disk"
  end

  test "trash mode moves the file to trash and flashes info", ctx do
    trash_root =
      Path.join(System.tmp_dir!(), "mydia_fe_trash_#{System.unique_integer([:positive])}")

    File.mkdir_p!(trash_root)
    Application.put_env(:mydia, :trash_dir, trash_root)
    on_exit(fn -> Application.delete_env(:mydia, :trash_dir) end)

    file = file_on_disk(ctx.library_path, ctx.media_item, "trashed.mkv", "data")
    abs = MediaFile.absolute_path(file)

    {:noreply, socket} = FileEvents.delete_media_file(%{}, delete_socket(ctx, file, :trash))

    refute File.exists?(abs)
    reloaded = Mydia.Repo.get(MediaFile, file.id)
    refute is_nil(reloaded.trashed_at)
    assert reloaded.trashed_reason == :manual
    assert flash_text(socket, :info) =~ "Moved to trash"
  end

  test "flashes an error but still deletes the record when removal fails", ctx do
    # A directory at the media path makes the on-disk removal fail.
    rel = "as_dir.mkv"
    File.mkdir_p!(Path.join(ctx.library_path.path, rel))

    {:ok, file} =
      Library.create_scanned_media_file(%{
        relative_path: rel,
        library_path_id: ctx.library_path.id,
        media_item_id: ctx.media_item.id,
        size: 1
      })

    file = Mydia.Repo.preload(file, :library_path)

    {:noreply, socket} = FileEvents.delete_media_file(%{}, delete_socket(ctx, file, :permanent))

    refute Mydia.Repo.get(MediaFile, file.id)
    assert flash_text(socket, :error) =~ "could not be deleted"
  end

  describe "pre_transcode/2" do
    test "authorizes the media file before creating a transcode job" do
      # Create a visible item and a hidden item
      visible_item =
        Mydia.MediaFixtures.categorized_media_item_fixture(%{type: "movie"}, "cartoon_movie")

      hidden_item = Mydia.MediaFixtures.categorized_media_item_fixture(%{type: "movie"}, "movie")

      # Create media files for each
      _visible_file = Mydia.MediaFixtures.media_file_fixture(%{media_item_id: visible_item.id})
      hidden_file = Mydia.MediaFixtures.media_file_fixture(%{media_item_id: hidden_item.id})

      # Create a restricted user
      restricted_user =
        Mydia.AccountsFixtures.restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]})

      socket =
        stub_socket(%{
          current_user: restricted_user,
          current_scope: Scope.for_user(restricted_user),
          media_item: visible_item
        })

      # Try to transcode a hidden file
      {:noreply, result_socket} =
        FileEvents.pre_transcode(
          %{"media-file-id" => hidden_file.id, "resolution" => "720p"},
          socket
        )

      # Verify no job was created
      refute Mydia.Repo.get_by(Mydia.Downloads.TranscodeJob, media_file_id: hidden_file.id)
      assert flash_text(result_socket, :error) == "Media file not found"
    end
  end
end
