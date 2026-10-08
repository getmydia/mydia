defmodule Mydia.StorageContractCase do
  @moduledoc """
  Behaviour tests every `Mydia.Storage` implementation must pass.

  The using module defines `put_fixture(context, relative_path, binary)`, which
  writes an object/file directly (bypassing Mydia.Storage), and a `setup` that
  returns `%{location: %Mydia.Storage.Location{}}`.
  """

  defmacro __using__(_opts) do
    # The contract is one long list of tests injected into each backend's module.
    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote do
      alias Mydia.Storage
      alias Mydia.Storage.{Entry, Error}

      test "list/1 returns every file with size and mtime, recursively", ctx do
        put_fixture(ctx, "Invented Film (2031)/film.mkv", "0123456789")
        put_fixture(ctx, "Show/Season 01/ep.mkv", "abc")

        assert {:ok, entries} = Storage.list(ctx.location)
        by_path = Map.new(entries, &{&1.relative_path, &1})

        assert %Entry{size: 10, mtime: %DateTime{}} = by_path["Invented Film (2031)/film.mkv"]
        assert %Entry{size: 3} = by_path["Show/Season 01/ep.mkv"]
      end

      test "stat/1 and exists?/1", ctx do
        put_fixture(ctx, "a.mkv", "hello")
        {:ok, source} = Storage.source(ctx.location, "a.mkv")
        {:ok, missing} = Storage.source(ctx.location, "missing.mkv")

        assert {:ok, %Entry{size: 5, relative_path: "a.mkv"}} = Storage.stat(source)
        assert Storage.exists?(source)
        assert {:error, %Error{kind: :not_found}} = Storage.stat(missing)
        refute Storage.exists?(missing)
      end

      test "read_range/3 returns exactly the requested bytes", ctx do
        put_fixture(ctx, "r.mkv", "0123456789")
        {:ok, source} = Storage.source(ctx.location, "r.mkv")

        assert {:ok, "234"} = Storage.read_range(source, 2, 3)
        assert {:ok, "89"} = Storage.read_range(source, 8, 2)
      end

      test "stream_range/5 folds every chunk of the range in order", ctx do
        body = :binary.copy("x", 300_000) <> "END"
        put_fixture(ctx, "big.mkv", body)
        {:ok, source} = Storage.source(ctx.location, "big.mkv")

        assert {:ok, chunks} =
                 Storage.stream_range(source, 299_998, 5, [], fn chunk, acc ->
                   {:ok, [chunk | acc]}
                 end)

        assert chunks |> Enum.reverse() |> IO.iodata_to_binary() == "xxEND"

        assert {:ok, total} =
                 Storage.stream_range(source, 0, byte_size(body), 0, fn chunk, acc ->
                   {:ok, acc + byte_size(chunk)}
                 end)

        assert total == byte_size(body)
      end

      test "stream_range/5 stops when the callback errors", ctx do
        put_fixture(ctx, "s.mkv", :binary.copy("y", 600_000))
        {:ok, source} = Storage.source(ctx.location, "s.mkv")

        assert {:error, :client_gone} =
                 Storage.stream_range(source, 0, 600_000, nil, fn _chunk, _acc ->
                   {:error, :client_gone}
                 end)
      end

      test "input/1 yields something ffprobe can open", ctx do
        put_fixture(ctx, "i.mkv", "data")
        {:ok, source} = Storage.source(ctx.location, "i.mkv")
        assert {:ok, input} = Storage.input(source)
        assert is_binary(input)
      end

      test "validate/1 succeeds on an existing root", ctx do
        assert :ok = Storage.validate(ctx.location)
      end

      defp local_file!(ctx, name, bin) do
        path = Path.join([ctx.tmp_dir, "outside", name])
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, bin)
        path
      end

      test "put_binary/3 creates, overwrites, and refuses an exclusive create", ctx do
        {:ok, src} = Storage.source(ctx.location, "Invented Film (2031)/film.nfo")

        assert :ok = Storage.put_binary(src, "one", mkdir: true)
        assert {:ok, "one"} = Storage.read(src)
        assert :ok = Storage.put_binary(src, ["tw", "o"])
        assert {:ok, "two"} = Storage.read(src)

        assert {:error, %Error{kind: :exists}} =
                 Storage.put_binary(src, "three", exclusive: true)

        assert {:ok, "two"} = Storage.read(src)

        {:ok, fresh} = Storage.source(ctx.location, "Invented Film (2031)/film.en.srt")
        assert :ok = Storage.put_binary(fresh, "cue", exclusive: true)
        assert {:ok, "cue"} = Storage.read(fresh)
      end

      test "put_file/3 uploads a local file", ctx do
        path = local_file!(ctx, "src.mkv", :binary.copy("p", 70_000))
        {:ok, dest} = Storage.source(ctx.location, "Show/Season 01/ep.mkv")

        assert :ok = Storage.put_file(dest, path)
        assert {:ok, %Entry{size: 70_000}} = Storage.stat(dest)
        assert File.exists?(path)
      end

      test "copy/2 keeps the source, move/2 removes it", ctx do
        put_fixture(ctx, "a/one.mkv", "12345")
        {:ok, one} = Storage.source(ctx.location, "a/one.mkv")
        {:ok, two} = Storage.source(ctx.location, "b/two.mkv")
        {:ok, three} = Storage.source(ctx.location, "c/three.mkv")

        assert :ok = Storage.copy(one, two)
        assert {:ok, "12345"} = Storage.read(one)
        assert {:ok, "12345"} = Storage.read(two)

        assert :ok = Storage.move(two, three)
        assert {:error, %Error{kind: :not_found}} = Storage.stat(two)
        assert {:ok, "12345"} = Storage.read(three)
      end

      test "delete/1 removes a file and is :ok for a missing one", ctx do
        put_fixture(ctx, "gone.mkv", "x")
        {:ok, src} = Storage.source(ctx.location, "gone.mkv")

        assert :ok = Storage.delete(src)
        refute Storage.exists?(src)
        assert :ok = Storage.delete(src)
      end

      test "delete_prefix/2 removes one folder and nothing beside it", ctx do
        put_fixture(ctx, "Show/Season 01/ep.mkv", "a")
        put_fixture(ctx, "Show/tvshow.nfo", "b")
        put_fixture(ctx, "Show 2/ep.mkv", "c")

        assert :ok = Storage.delete_prefix(ctx.location, "Show")

        assert {:ok, entries} = Storage.list(ctx.location)
        assert Enum.map(entries, & &1.relative_path) == ["Show 2/ep.mkv"]
      end

      test "delete_prefix/2 refuses the whole location", ctx do
        put_fixture(ctx, "keep.mkv", "k")

        for root <- ["", ".", "/", "./", "..", "a/.."] do
          assert {:error, %Error{kind: :misconfigured}} =
                   Storage.delete_prefix(ctx.location, root)
        end

        assert {:ok, [_]} = Storage.list(ctx.location)
      end

      test "ls/1 names the files directly inside a directory", ctx do
        put_fixture(ctx, "Film/film.mkv", "v")
        put_fixture(ctx, "Film/film.en.srt", "s")
        put_fixture(ctx, "Film/Extras/x.mkv", "e")

        dir = Path.join(ctx.location.uri, "Film")
        assert {:ok, names} = Storage.ls(dir)
        assert "film.mkv" in names
        assert "film.en.srt" in names
        refute "Extras/x.mkv" in names
        refute "x.mkv" in names
      end

      test "at/1 resolves a stored path and the path helpers use it", ctx do
        put_fixture(ctx, "Film/film.mkv", "data")
        path = Path.join(ctx.location.uri, "Film/film.mkv")

        assert {:ok, %Mydia.Storage.Source{path: ^path} = src} = Storage.at(path)
        assert {:ok, %Entry{size: 4}} = Storage.stat(src)
        assert Storage.path_exists?(path)
        assert {:ok, "data"} = Storage.read_path(path)
        assert :ok = Storage.delete_path(path)
        refute Storage.path_exists?(path)
        assert :ok = Storage.delete_path(path)
      end

      test "download/2 writes the bytes to a local file", ctx do
        put_fixture(ctx, "d.mkv", :binary.copy("d", 300_000))
        {:ok, src} = Storage.source(ctx.location, "d.mkv")
        dest = Path.join([ctx.tmp_dir, "outside", "dl", "d.mkv"])

        assert :ok = Storage.download(src, dest)
        assert File.read!(dest) == :binary.copy("d", 300_000)
      end
    end
  end
end
