defmodule Mydia.StorageContractCase do
  @moduledoc """
  Behaviour tests every `Mydia.Storage` implementation must pass.

  The using module defines `put_fixture(context, relative_path, binary)`, which
  writes an object/file directly (bypassing Mydia.Storage), and a `setup` that
  returns `%{location: %Mydia.Storage.Location{}}`.
  """

  defmacro __using__(_opts) do
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
    end
  end
end
