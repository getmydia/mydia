defmodule Mydia.Library.BulkRenameTest do
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library.BulkRename
  alias Mydia.Library.Structs.BulkRenamePreview

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    library_path = library_path_fixture(%{path: tmp_dir, type: "mixed"})
    movie = media_item_fixture(%{type: "movie", title: "Paper Comet", year: 2019})
    show = media_item_fixture(%{type: "tv_show", title: "The Lantern Keepers", year: 2021})

    ep =
      episode_fixture(%{
        media_item_id: show.id,
        season_number: 1,
        episode_number: 1,
        title: ""
      })

    %{lp: library_path, root: tmp_dir, movie: movie, show: show, ep: ep}
  end

  defp touch(root, rel) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, rel)
    rel
  end

  defp movie_file(ctx, rel) do
    touch(ctx.root, rel)

    media_file_fixture(%{
      media_item_id: ctx.movie.id,
      library_path_id: ctx.lp.id,
      relative_path: rel
    })
  end

  defp episode_file(ctx, rel, attrs \\ %{}) do
    touch(ctx.root, rel)

    media_file_fixture(
      Map.merge(
        %{episode_id: ctx.ep.id, library_path_id: ctx.lp.id, relative_path: rel},
        attrs
      )
    )
  end

  # Renames an episode file to its canonical name, giving a stable "unchanged" file.
  defp canonical_episode(ctx) do
    file = episode_file(ctx, "tmp.s01e01.mkv")
    preview = Mydia.Library.FileRenamer.generate_rename_preview(file)
    assert {:ok, file} = Mydia.Library.FileRenamer.rename_file(file, preview.proposed_path)
    file
  end

  test "preview counts changed and unchanged files", ctx do
    movie_file(ctx, "paper.comet.junk.mkv")
    canonical_episode(ctx)

    assert {:ok, %BulkRenamePreview{total: 2, changed: 1, unchanged: 1, conflicts: [], sample: s}} =
             BulkRename.preview(ctx.lp)

    assert length(s) == 1
  end

  test "a proposed name already on disk is a target_exists conflict", ctx do
    file = movie_file(ctx, "paper.comet.junk.mkv")
    preview = Mydia.Library.FileRenamer.generate_rename_preview(file)
    File.mkdir_p!(Path.dirname(preview.proposed_path))
    File.write!(preview.proposed_path, "taken")

    assert {:ok, %{conflicts: [{p, :target_exists}], sample: []}} = BulkRename.preview(ctx.lp)
    assert p.file_id == file.id

    assert {:ok, %{renamed: 0, conflicts: 1}} = BulkRename.run(ctx.lp)
    assert File.exists?(Path.join(ctx.root, "paper.comet.junk.mkv"))
  end

  test "two files proposing one name are both duplicate_target conflicts and neither moves on run",
       ctx do
    episode_file(ctx, "a.s01e01.mkv")
    episode_file(ctx, "b.s01e01.mkv", %{})

    assert {:ok, %{conflicts: conflicts}} = BulkRename.preview(ctx.lp)
    assert [{_, :duplicate_target}, {_, :duplicate_target}] = conflicts

    assert {:ok, %{renamed: 0, conflicts: 2}} = BulkRename.run(ctx.lp)
    assert File.exists?(Path.join(ctx.root, "a.s01e01.mkv"))
    assert File.exists?(Path.join(ctx.root, "b.s01e01.mkv"))
  end

  test "files in another library are ignored", ctx do
    other_root = Path.join(ctx.root, "other")
    File.mkdir_p!(other_root)
    other = library_path_fixture(%{path: other_root, type: "movies"})
    File.write!(Path.join(other_root, "junk.mkv"), "x")

    media_file_fixture(%{
      media_item_id: ctx.movie.id,
      library_path_id: other.id,
      relative_path: "junk.mkv"
    })

    assert {:ok, %{total: 0, changed: 0}} = BulkRename.preview(ctx.lp)
  end

  test "run renames changed files, carries sidecars, and is idempotent", ctx do
    file = movie_file(ctx, "paper.comet.junk.mkv")
    touch(ctx.root, "paper.comet.junk.nfo")

    assert {:ok, %{renamed: 1, errors: 0}} = BulkRename.run(ctx.lp)

    moved = Mydia.Library.get_media_file!(file.id)
    refute moved.relative_path == "paper.comet.junk.mkv"
    refute File.exists?(Path.join(ctx.root, "paper.comet.junk.mkv"))
    refute File.exists?(Path.join(ctx.root, "paper.comet.junk.nfo"))
    assert File.exists?(Path.join(ctx.root, moved.relative_path))
    assert File.exists?(Path.join(ctx.root, Path.rootname(moved.relative_path) <> ".nfo"))

    assert {:ok, %{renamed: 0, unchanged: 1}} = BulkRename.run(ctx.lp)
  end

  describe "Sonarr and Radarr default names" do
    test "get no bogus group suffix and stay stable on a second run", ctx do
      ep_file = episode_file(ctx, "The Lantern Keepers - S01E01 - Pilot WEBDL-1080p.mkv")
      movie = movie_file(ctx, "Paper Comet (2019) Bluray-1080p.mkv")

      assert {:ok, %{sample: sample}} = BulkRename.preview(ctx.lp)
      names = Map.new(sample, &{&1.file_id, Path.basename(&1.proposed_path)})

      assert names[ep_file.id] =~ ~r/^The Lantern Keepers \(2021\) - S01E01 - [^-]*\.mkv$/
      assert names[movie.id] =~ ~r/^Paper Comet \(2019\)[^-]*\.mkv$/

      assert {:ok, %{renamed: 2, errors: 0}} = BulkRename.run(ctx.lp)
      assert {:ok, %{renamed: 0, unchanged: 2}} = BulkRename.run(ctx.lp)
    end

    test "a canonical name with no quality fields gets no suffix", ctx do
      file = episode_file(ctx, "The Lantern Keepers (2021) - S01E01 - Pilot.mkv")

      assert {:ok, %{sample: [preview]}} = BulkRename.preview(ctx.lp)
      assert preview.file_id == file.id
      refute Path.basename(preview.proposed_path) =~ "-Pilot"
    end

    test "a scene name keeps its group and is idempotent", ctx do
      file = movie_file(ctx, "Paper.Comet.2019.1080p.BluRay.x264-GROUP.mkv")

      assert {:ok, %{renamed: 1}} = BulkRename.run(ctx.lp)
      assert Mydia.Library.get_media_file!(file.id).relative_path =~ ~r/-GROUP\.mkv$/
      assert {:ok, %{renamed: 0, unchanged: 1}} = BulkRename.run(ctx.lp)
    end
  end

  describe "rows that change after planning" do
    # Runs with two groups and calls `change` on whichever file the first group
    # did not touch, between the two groups.
    defp run_changing_second(ctx, change) do
      files = [movie_file(ctx, "paper.comet.junk.mkv"), episode_file(ctx, "lk.s01e01.mkv")]

      on_progress = fn
        {1, 2} ->
          [pending] = Enum.filter(files, &File.exists?(Path.join(ctx.root, &1.relative_path)))
          send(self(), {:pending, pending})
          change.(pending)

        _ ->
          :ok
      end

      result = BulkRename.run(ctx.lp, on_progress: on_progress)
      assert_received {:pending, pending}
      {result, pending}
    end

    test "a file trashed meanwhile is skipped", ctx do
      {result, pending} =
        run_changing_second(ctx, fn file ->
          Mydia.Repo.update!(Ecto.Changeset.change(file, trashed_at: DateTime.utc_now(:second)))
        end)

      assert {:ok, %{renamed: 1, unchanged: 1, errors: 0}} = result
      assert File.exists?(Path.join(ctx.root, pending.relative_path))
    end

    test "a file moved to another library meanwhile is skipped", ctx do
      other = library_path_fixture(%{path: Path.join(ctx.root, "other"), type: "mixed"})

      {result, pending} =
        run_changing_second(ctx, fn file ->
          Mydia.Repo.update!(Ecto.Changeset.change(file, library_path_id: other.id))
        end)

      assert {:ok, %{renamed: 1, unchanged: 1}} = result
      assert File.exists?(Path.join(ctx.root, pending.relative_path))
    end

    test "a file renamed meanwhile is left at its new name", ctx do
      {result, pending} =
        run_changing_second(ctx, fn file ->
          File.rename!(Path.join(ctx.root, file.relative_path), Path.join(ctx.root, "moved.mkv"))
          Mydia.Repo.update!(Ecto.Changeset.change(file, relative_path: "moved.mkv"))
        end)

      assert {:ok, %{renamed: 1, unchanged: 1}} = result
      assert Mydia.Library.get_media_file!(pending.id).relative_path == "moved.mkv"
      assert File.exists?(Path.join(ctx.root, "moved.mkv"))
    end
  end

  test "run reports progress once per media item", ctx do
    movie_file(ctx, "paper.comet.junk.mkv")
    episode_file(ctx, "lk.s01e01.mkv")
    me = self()

    assert {:ok, _} = BulkRename.run(ctx.lp, on_progress: &send(me, {:progress, &1}))

    assert_received {:progress, {1, 2}}
    assert_received {:progress, {2, 2}}
    refute_received {:progress, _}
  end

  test "an unmounted library path is library_unavailable", ctx do
    gone = library_path_fixture(%{path: Path.join(ctx.root, "missing"), type: "movies"})

    assert {:error, :library_unavailable} = BulkRename.preview(gone)
    assert {:error, :library_unavailable} = BulkRename.run(gone)
  end

  test "run renames even when auto_rename is false", ctx do
    {:ok, lp} = Mydia.Settings.update_library_path(ctx.lp, %{auto_rename: false})
    movie_file(ctx, "paper.comet.junk.mkv")

    assert {:ok, %{renamed: 1}} = BulkRename.run(lp)
  end
end
