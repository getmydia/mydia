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

  defp delete_socket(ctx, file, delete_file_from_disk) do
    stub_socket(%{
      current_user: ctx.user,
      current_scope: Scope.for_user(ctx.user),
      media_item: ctx.media_item,
      file_to_delete: file,
      delete_file_from_disk: delete_file_from_disk
    })
  end

  test "deletes the file and flashes info when delete_file_from_disk is true", ctx do
    file = file_on_disk(ctx.library_path, ctx.media_item, "movie.mkv", "data")
    abs = MediaFile.absolute_path(file)

    {:noreply, socket} = FileEvents.delete_media_file(%{}, delete_socket(ctx, file, true))

    refute File.exists?(abs)
    refute Mydia.Repo.get(MediaFile, file.id)
    assert flash_text(socket, :info) =~ "including the file on disk"
  end

  test "keeps the file and flashes info when delete_file_from_disk is false", ctx do
    file = file_on_disk(ctx.library_path, ctx.media_item, "keep.mkv", "data")
    abs = MediaFile.absolute_path(file)

    {:noreply, socket} = FileEvents.delete_media_file(%{}, delete_socket(ctx, file, false))

    assert File.exists?(abs)
    refute Mydia.Repo.get(MediaFile, file.id)
    assert flash_text(socket, :info) =~ "kept on disk"
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

    {:noreply, socket} = FileEvents.delete_media_file(%{}, delete_socket(ctx, file, true))

    refute Mydia.Repo.get(MediaFile, file.id)
    assert flash_text(socket, :error) =~ "could not be deleted"
  end
end
