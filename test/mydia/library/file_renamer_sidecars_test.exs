defmodule Mydia.Library.FileRenamerSidecarsTest do
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library.FileRenamer
  alias Mydia.Subtitles.Subtitle

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    library_path = library_path_fixture(%{path: tmp_dir, type: "series"})
    show = media_item_fixture(%{type: "tv_show", title: "The Lantern Keepers", year: 2021})

    ep = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})

    for name <- ["lk.s01e01.mkv", "lk.s01e01.nfo", "lk.s01e01.en.srt", "lk.s01e01-thumb.jpg"] do
      File.write!(Path.join(tmp_dir, name), name)
    end

    file =
      media_file_fixture(%{
        episode_id: ep.id,
        library_path_id: library_path.id,
        relative_path: "lk.s01e01.mkv"
      })

    preview = FileRenamer.generate_rename_preview(file)
    root = Path.rootname(preview.proposed_path)

    %{mf: file, root: tmp_dir, proposed: preview.proposed_path, proposed_root: root}
  end

  test "renaming an episode renames its nfo, subtitles and thumb", ctx do
    assert {:ok, _} = FileRenamer.rename_file(ctx.mf, ctx.proposed)

    for tail <- [".mkv", ".nfo", ".en.srt", "-thumb.jpg"] do
      assert File.exists?(ctx.proposed_root <> tail), "missing #{tail}"
      refute File.exists?(Path.join(ctx.root, "lk.s01e01" <> tail))
    end
  end

  test "a taken sidecar destination stays behind and the video still renames", ctx do
    File.mkdir_p!(Path.dirname(ctx.proposed))
    File.write!(ctx.proposed_root <> ".nfo", "taken")

    assert {:ok, _} = FileRenamer.rename_file(ctx.mf, ctx.proposed)

    assert File.exists?(ctx.proposed)
    assert File.exists?(Path.join(ctx.root, "lk.s01e01.nfo"))
    assert File.read!(ctx.proposed_root <> ".nfo") == "taken"
  end

  test "a subtitle row follows its file", ctx do
    {:ok, sub} =
      %Subtitle{}
      |> Subtitle.changeset(%{
        media_file_id: ctx.mf.id,
        language: "en",
        provider: "test",
        subtitle_hash: "hash-lk-en",
        file_path: Path.join(ctx.root, "lk.s01e01.en.srt"),
        format: "srt"
      })
      |> Repo.insert()

    assert {:ok, _} = FileRenamer.rename_file(ctx.mf, ctx.proposed)

    assert Repo.get!(Subtitle, sub.id).file_path == ctx.proposed_root <> ".en.srt"
  end

  test "an unlistable folder fails before the video moves", ctx do
    File.chmod!(ctx.root, 0o300)
    on_exit(fn -> File.chmod(ctx.root, 0o755) end)

    case File.ls(ctx.root) do
      {:ok, _} ->
        # Root (or a permissive mount) can list it anyway.
        File.chmod!(ctx.root, 0o755)
        IO.puts("skipped: directory permissions are not enforced for this user")

      {:error, _} ->
        assert {:error, {:sidecars_unlisted, _}} = FileRenamer.rename_file(ctx.mf, ctx.proposed)
        File.chmod!(ctx.root, 0o755)
        assert File.exists?(Path.join(ctx.root, "lk.s01e01.mkv"))
    end
  end
end
