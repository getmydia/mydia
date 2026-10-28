defmodule Mydia.Library.LibraryMoveFileStepTest do
  use Mydia.DataCase, async: false

  @moduletag :tmp_dir

  alias Mydia.Library.LibraryMove.FileStep
  alias Mydia.Library.LibraryMove.Move
  alias Mydia.Library.MediaFile
  alias Mydia.Repo

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  @rel "Glass Harbor (2019)/glass.mkv"

  setup %{tmp_dir: tmp} do
    a = library_path_fixture(%{type: "movies", path: Path.join(tmp, "a")})
    b = library_path_fixture(%{type: "movies", path: Path.join(tmp, "b")})
    movie = media_item_fixture(%{type: "movie", title: "Glass Harbor", year: 2019})
    source = Path.join(a.path, @rel)
    dest = Path.join(b.path, @rel)
    write(source, "video")
    File.mkdir_p!(Path.dirname(dest))

    file =
      %{media_item_id: movie.id, library_path_id: a.id, relative_path: @rel, size: 5}
      |> media_file_fixture()
      |> Repo.preload(:library_path, force: true)

    move = %Move{
      media_file: file,
      source_path: source,
      dest_path: dest,
      dest_rel: @rel,
      action: :copy
    }

    %{a: a, b: b, movie: movie, mf: file, move: move, source: source, dest: dest}
  end

  defp write(path, body) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
  end

  describe "discard_partial/4" do
    test "removes an unclaimed separate copy once the row is lost", ctx do
      File.cp!(ctx.source, ctx.dest)

      assert {:error, :media_file_moved} =
               FileStep.discard_partial(ctx.move, ctx.b, :media_file_moved, false)

      refute File.exists?(ctx.dest)
      assert File.exists?(ctx.source)
    end

    test "keeps a copy before the last attempt of a transient failure", ctx do
      File.cp!(ctx.source, ctx.dest)
      FileStep.discard_partial(ctx.move, ctx.b, :busy, false)
      assert File.read!(ctx.dest) == "video"
    end

    test "keeps a destination a row claims", ctx do
      File.cp!(ctx.source, ctx.dest)

      media_file_fixture(%{
        media_item_id: ctx.movie.id,
        library_path_id: ctx.b.id,
        relative_path: @rel
      })

      FileStep.discard_partial(ctx.move, ctx.b, :busy, true)

      assert File.read!(ctx.dest) == "video"
    end

    test "keeps a destination that is the source's own inode", ctx do
      File.ln!(ctx.source, ctx.dest)
      FileStep.discard_partial(ctx.move, ctx.b, :busy, true)
      assert File.read!(ctx.dest) == "video"
      assert File.read!(ctx.source) == "video"
    end

    test "keeps the only copy when the source is gone", ctx do
      File.cp!(ctx.source, ctx.dest)
      File.rm!(ctx.source)

      FileStep.discard_partial(ctx.move, ctx.b, :media_file_gone, true)

      assert File.read!(ctx.dest) == "video"
    end

    test "keeps a destination whose bytes differ from the source", ctx do
      write(ctx.dest, "other")
      FileStep.discard_partial(ctx.move, ctx.b, :media_file_gone, true)
      assert File.read!(ctx.dest) == "other"
    end
  end

  describe "run/3" do
    test "a move the plan marked as a conflict touches nothing", ctx do
      assert {:skipped_conflict, []} = FileStep.run(%{ctx.move | conflict: true}, ctx.b, true)
      refute File.exists?(ctx.dest)
      assert Repo.get!(MediaFile, ctx.mf.id).library_path_id == ctx.a.id
    end
  end

  describe "finish_source/4" do
    test "keeps a source a scan re-registered after the relink", ctx do
      File.ln!(ctx.source, ctx.dest)
      Repo.update!(Ecto.Changeset.change(ctx.mf, library_path_id: ctx.b.id))

      media_file_fixture(%{
        media_item_id: ctx.movie.id,
        library_path_id: ctx.a.id,
        relative_path: @rel
      })

      srt = Path.join(Path.dirname(ctx.source), "glass.en.srt")
      write(srt, "1")

      assert {:moved, [^srt]} = FileStep.finish_source(ctx.mf, ctx.dest, ctx.b, [srt])

      assert File.exists?(ctx.source)
      assert File.exists?(srt)
    end

    test "deletes the source and carries the sidecars otherwise", ctx do
      File.ln!(ctx.source, ctx.dest)
      Repo.update!(Ecto.Changeset.change(ctx.mf, library_path_id: ctx.b.id))
      srt = Path.join(Path.dirname(ctx.source), "glass.en.srt")
      write(srt, "1")

      assert {:moved, []} = FileStep.finish_source(ctx.mf, ctx.dest, ctx.b, [srt])

      refute File.exists?(ctx.source)
      assert File.exists?(Path.join(Path.dirname(ctx.dest), "glass.en.srt"))
    end
  end

  describe "run/3 on object storage" do
    @describetag :s3

    test "an object of another size at the destination is a conflict, not a retry", ctx do
      {lp, loc} = Mydia.S3Helpers.library_path!("movies")
      on_exit(fn -> Mydia.S3Helpers.delete_prefix!(loc) end)
      Mydia.S3Helpers.put_object!(loc, @rel, "someone else's bytes")
      dest = lp.path <> "/" <> @rel

      move = %{ctx.move | dest_path: dest}

      assert {:skipped_conflict, []} = FileStep.run(move, lp, false)
      assert File.exists?(ctx.source)
      assert Repo.get!(MediaFile, ctx.mf.id).library_path_id == ctx.a.id
    end
  end
end
