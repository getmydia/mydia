defmodule Mydia.Library.TrashEpisodeFilesTest do
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library
  alias Mydia.Media.Episode
  alias Mydia.Library.{MediaFile, MediaFileEpisode}
  alias Mydia.Repo

  setup do
    on_exit(fn -> Application.delete_env(:mydia, :trash_dir) end)
    :ok
  end

  defp setup_show(tmp_dir) do
    root = Path.join(tmp_dir, "lib")
    File.mkdir_p!(root)
    library_path = library_path_fixture(%{path: root, type: "series"})
    show = media_item_fixture(%{type: "tv_show", title: "Harrowgate Nights"})
    %{root: root, library_path: library_path, show: show}
  end

  defp add_file(ctx, episode, rel, content) do
    path = Path.join(ctx.root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)

    {:ok, file} =
      Library.create_scanned_media_file(%{
        relative_path: rel,
        library_path_id: ctx.library_path.id,
        episode_id: episode.id,
        size: byte_size(content)
      })

    Repo.preload(file, :library_path)
  end

  defp episode(ctx, season, number),
    do:
      episode_fixture(%{
        media_item_id: ctx.show.id,
        season_number: season,
        episode_number: number
      })

  defp link(file, episode),
    do: Repo.insert!(%MediaFileEpisode{media_file_id: file.id, episode_id: episode.id})

  describe "episode_files_for_removal/1" do
    @tag :tmp_dir
    test "lists a linked multi-episode file once and blocks one reaching outside",
         %{tmp_dir: tmp} do
      ctx = setup_show(tmp)
      e9 = episode(ctx, 1, 9)
      e10 = episode(ctx, 1, 10)
      s2 = episode(ctx, 2, 1)
      inside = add_file(ctx, e9, "s1e09e10.mkv", "aaaa")
      link(inside, e10)
      spanning = add_file(ctx, e10, "s1e10s2e01.mkv", "bb")
      link(spanning, s2)

      assert %{removable: [r], blocked: [b]} =
               Library.episode_files_for_removal([e9.id, e10.id])

      assert r.id == inside.id
      assert b.id == spanning.id
    end
  end

  describe "trash_episode_files/2" do
    @tag :tmp_dir
    test "takes a file linked only through media_file_episodes", %{tmp_dir: tmp} do
      ctx = setup_show(tmp)
      e9 = episode(ctx, 1, 9)
      e10 = episode(ctx, 1, 10)
      f = add_file(ctx, e9, "s1e09e10.mkv", "aaaa")
      link(f, e10)
      # The primary episode is outside the set, so the file stays.
      assert {:ok, %{trashed: [], failed: [{held, :covers_other_episodes}]}} =
               Library.trash_episode_files([e10.id], reason: :manual)

      assert held.id == f.id
      assert is_nil(Repo.get!(MediaFile, f.id).trashed_at)

      assert {:ok, %{trashed: [t], failed: [], bytes: 4}} =
               Library.trash_episode_files([e9.id, e10.id], reason: :manual)

      assert t.id == f.id
    end

    @tag :tmp_dir
    test "leaves a file that also covers an episode in another season", %{tmp_dir: tmp} do
      ctx = setup_show(tmp)
      s1 = episode(ctx, 1, 10)
      s2 = episode(ctx, 2, 1)
      f = add_file(ctx, s1, "s1e10s2e01.mkv", "aaaa")
      link(f, s2)

      assert {:ok, %{trashed: [], failed: [{_, :covers_other_episodes}], bytes: 0}} =
               Library.trash_episode_files([s1.id], reason: :manual)

      assert is_nil(Repo.get!(MediaFile, f.id).trashed_at)
    end

    @tag :tmp_dir
    test "trashes every live file on the episodes, including extra versions", %{tmp_dir: tmp} do
      ctx = setup_show(tmp)
      e1 = episode(ctx, 1, 1)
      e2 = episode(ctx, 1, 2)
      f1 = add_file(ctx, e1, "s1e1.mkv", "aaaa")
      f2 = add_file(ctx, e1, "s1e1-alt.mkv", "bbbbbb")
      f3 = add_file(ctx, e2, "s1e2.mkv", "cc")

      assert {:ok, %{trashed: trashed, failed: [], bytes: bytes}} =
               Library.trash_episode_files([e1.id, e2.id], reason: :smart_space)

      assert length(trashed) == 3
      assert bytes == 12

      for f <- [f1, f2, f3] do
        reloaded = Repo.get!(MediaFile, f.id)
        assert reloaded.trashed_at
        assert reloaded.trashed_reason == :smart_space
      end
    end

    @tag :tmp_dir
    test "leaves other seasons and episode rows untouched", %{tmp_dir: tmp} do
      ctx = setup_show(tmp)
      e1 = episode(ctx, 1, 1)
      s2 = episode(ctx, 2, 1)
      add_file(ctx, e1, "s1e1.mkv", "aaaa")
      other = add_file(ctx, s2, "s2e1.mkv", "dddd")

      assert {:ok, %{trashed: [_]}} = Library.trash_episode_files([e1.id], reason: :smart_space)

      assert is_nil(Repo.get!(MediaFile, other.id).trashed_at)
      assert Repo.get!(Episode, e1.id)
      assert Repo.get!(Episode, s2.id)
    end

    @tag :tmp_dir
    test "skips already-trashed files", %{tmp_dir: tmp} do
      ctx = setup_show(tmp)
      e1 = episode(ctx, 1, 1)
      f1 = add_file(ctx, e1, "s1e1.mkv", "aaaa")
      add_file(ctx, e1, "s1e1-alt.mkv", "bb")
      {:ok, _} = Library.trash_media_file(f1, reason: :manual)

      assert {:ok, %{trashed: [t], bytes: 2}} =
               Library.trash_episode_files([e1.id], reason: :smart_space)

      refute t.id == f1.id
      assert Repo.get!(MediaFile, f1.id).trashed_reason == :manual
    end

    @tag :tmp_dir
    test "reports a failure and keeps going", %{tmp_dir: tmp} do
      ctx = setup_show(tmp)
      e1 = episode(ctx, 1, 1)
      bad = add_file(ctx, e1, "locked/s1e1.mkv", "aaaa")
      good = add_file(ctx, e1, "s1e1-alt.mkv", "bb")

      # A read-only directory: the file cannot be moved out of it.
      File.chmod!(Path.join(ctx.root, "locked"), 0o500)
      on_exit(fn -> File.chmod(Path.join(ctx.root, "locked"), 0o700) end)

      assert {:ok, %{trashed: [t], failed: [{failed_file, _reason}], bytes: 2}} =
               Library.trash_episode_files([e1.id], reason: :smart_space)

      assert t.id == good.id
      assert failed_file.id == bad.id
      assert is_nil(Repo.get!(MediaFile, bad.id).trashed_at)
    end
  end

  describe "trash_media_files/2" do
    @tag :tmp_dir
    test "trashes exactly the listed live files and reports failures", %{tmp_dir: tmp} do
      ctx = setup_show(tmp)
      e1 = episode(ctx, 1, 1)
      f1 = add_file(ctx, e1, "a.mkv", "aaaa")
      f2 = add_file(ctx, e1, "b.mkv", "bb")
      other = add_file(ctx, e1, "c.mkv", "c")
      {:ok, _} = Library.trash_media_file(f2, reason: :manual)

      assert {:ok, %{trashed: [t], failed: [], bytes: 4}} =
               Library.trash_media_files([f1.id, f2.id, Ecto.UUID.generate()],
                 reason: :smart_space
               )

      assert t.id == f1.id
      assert Repo.get!(MediaFile, f2.id).trashed_reason == :manual
      assert is_nil(Repo.get!(MediaFile, other.id).trashed_at)
      assert {:ok, %{trashed: [], failed: [], bytes: 0}} = Library.trash_media_files([])
    end
  end

  describe "delete_episode_files/2" do
    @tag :tmp_dir
    test "deletes a linked file once and leaves one reaching outside", %{tmp_dir: tmp} do
      ctx = setup_show(tmp)
      e9 = episode(ctx, 1, 9)
      e10 = episode(ctx, 1, 10)
      s2 = episode(ctx, 2, 1)
      inside = add_file(ctx, e9, "s1e09e10.mkv", "aaaa")
      link(inside, e10)
      spanning = add_file(ctx, e10, "s1e10s2e01.mkv", "bb")
      link(spanning, s2)

      assert {:ok, %{deleted: [d], failed: [{held, :covers_other_episodes}], bytes: 4}} =
               Library.delete_episode_files([e9.id, e10.id], delete_files: true)

      assert d.id == inside.id
      assert held.id == spanning.id
      assert Repo.get(MediaFile, spanning.id)
      assert File.exists?(Path.join(ctx.root, "s1e10s2e01.mkv"))
    end

    @tag :tmp_dir
    test "delete_files: true removes rows and bytes", %{tmp_dir: tmp} do
      ctx = setup_show(tmp)
      e1 = episode(ctx, 1, 1)
      f1 = add_file(ctx, e1, "s1e1.mkv", "aaaa")
      f2 = add_file(ctx, e1, "s1e1-alt.mkv", "bb")

      assert {:ok, %{deleted: deleted, failed: [], bytes: 6}} =
               Library.delete_episode_files([e1.id], delete_files: true)

      assert length(deleted) == 2
      assert is_nil(Repo.get(MediaFile, f1.id))
      refute File.exists?(Path.join(ctx.root, "s1e1.mkv"))
      refute File.exists?(Path.join(ctx.root, "s1e1-alt.mkv"))
      assert is_nil(Repo.get(MediaFile, f2.id))
    end

    @tag :tmp_dir
    test "delete_files: false removes rows and keeps bytes", %{tmp_dir: tmp} do
      ctx = setup_show(tmp)
      e1 = episode(ctx, 1, 1)
      f1 = add_file(ctx, e1, "s1e1.mkv", "aaaa")

      assert {:ok, %{deleted: [_], failed: [], bytes: 4}} =
               Library.delete_episode_files([e1.id], delete_files: false)

      assert is_nil(Repo.get(MediaFile, f1.id))
      assert File.exists?(Path.join(ctx.root, "s1e1.mkv"))
    end
  end
end
