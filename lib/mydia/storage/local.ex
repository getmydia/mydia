defmodule Mydia.Storage.Local do
  @moduledoc "Local-disk storage. A thin wrapper over `File`."
  @behaviour Mydia.Storage.Backend

  alias Mydia.Storage.{Entry, Error, Location}

  @chunk_size 256 * 1024

  @impl true
  def validate(%Location{root: root}) do
    case File.ls(root) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, Error.from_posix(reason, root)}
    end
  end

  @impl true
  def list(%Location{root: root} = location) do
    with :ok <- validate(location) do
      {:ok, walk(root, root, [])}
    end
  end

  @impl true
  def stat(%Location{root: root}, rel) do
    path = Path.join(root, rel)

    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} ->
        {:ok, %Entry{relative_path: rel, size: size, mtime: DateTime.from_unix!(mtime)}}

      {:ok, _other} ->
        {:error, Error.new(:not_found, "not a regular file: #{path}")}

      {:error, reason} ->
        {:error, Error.from_posix(reason, path)}
    end
  end

  @impl true
  def input(%Location{root: root} = location, rel) do
    with {:ok, _} <- stat(location, rel), do: {:ok, Path.join(root, rel)}
  end

  @impl true
  def read_range(%Location{root: root}, rel, offset, length) do
    path = Path.join(root, rel)

    with {:ok, io} <- open(path) do
      try do
        case :file.pread(io, offset, length) do
          {:ok, data} -> {:ok, data}
          :eof -> {:ok, ""}
          {:error, reason} -> {:error, Error.from_posix(reason, path)}
        end
      after
        File.close(io)
      end
    end
  end

  @impl true
  def stream_range(%Location{root: root}, rel, offset, length, acc, fun) do
    path = Path.join(root, rel)

    with {:ok, io} <- open(path) do
      try do
        pread_loop(io, path, offset, offset + length, acc, fun)
      after
        File.close(io)
      end
    end
  end

  @impl true
  def put_file(%Location{root: root}, rel, local_path, _opts) do
    dest = Path.join(root, rel)

    with :ok <- mkdir_parent(dest) do
      case File.cp(local_path, dest) do
        :ok -> :ok
        {:error, reason} -> {:error, Error.from_posix(reason, dest)}
      end
    end
  end

  @impl true
  def put_binary(%Location{root: root}, rel, data, opts) do
    dest = Path.join(root, rel)

    with :ok <- if(Keyword.get(opts, :mkdir, false), do: mkdir_parent(dest), else: :ok) do
      if Keyword.get(opts, :exclusive, false),
        do: write_exclusive(dest, data),
        else: write_atomic(dest, data)
    end
  end

  @impl true
  def copy(%Location{root: from_root}, from_rel, %Location{root: to_root}, to_rel) do
    from = Path.join(from_root, from_rel)
    to = Path.join(to_root, to_rel)

    with :ok <- mkdir_parent(to) do
      case File.cp(from, to) do
        :ok -> :ok
        {:error, reason} -> {:error, Error.from_posix(reason, from)}
      end
    end
  end

  @impl true
  def move(
        %Location{root: from_root} = from_loc,
        from_rel,
        %Location{root: to_root} = to_loc,
        to_rel
      ) do
    from = Path.join(from_root, from_rel)
    to = Path.join(to_root, to_rel)

    with :ok <- mkdir_parent(to) do
      case File.rename(from, to) do
        :ok ->
          :ok

        {:error, :exdev} ->
          with :ok <- copy(from_loc, from_rel, to_loc, to_rel) do
            case delete(from_loc, from_rel) do
              :ok ->
                :ok

              {:error, _} = error ->
                File.rm(to)
                error
            end
          end

        {:error, reason} ->
          {:error, Error.from_posix(reason, from)}
      end
    end
  end

  @impl true
  def delete(%Location{root: root}, rel) do
    path = Path.join(root, rel)

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, Error.from_posix(reason, path)}
    end
  end

  @impl true
  def delete_prefix(%Location{root: root}, rel_dir) do
    case File.rm_rf(Path.join(root, rel_dir)) do
      {:ok, _} -> :ok
      {:error, reason, path} -> {:error, Error.from_posix(reason, path)}
    end
  end

  @impl true
  def ls(%Location{root: root}, rel_dir) do
    dir = Path.join(root, rel_dir)

    case File.ls(dir) do
      {:ok, names} -> {:ok, names}
      {:error, reason} -> {:error, Error.from_posix(reason, dir)}
    end
  end

  defp write_exclusive(dest, data) do
    case File.write(dest, data, [:exclusive]) do
      :ok -> :ok
      {:error, reason} -> {:error, Error.from_posix(reason, dest)}
    end
  end

  # Write to a sibling and rename over the target, so a reader never sees half
  # a file. This is what the NFO writer has always done.
  defp write_atomic(dest, data) do
    tmp = dest <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.write(tmp, data),
         :ok <- File.rename(tmp, dest) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, Error.from_posix(reason, dest)}
    end
  end

  defp mkdir_parent(path) do
    dir = Path.dirname(path)

    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, Error.from_posix(reason, dir)}
    end
  end

  defp pread_loop(_io, _path, pos, stop, acc, _fun) when pos >= stop, do: {:ok, acc}

  defp pread_loop(io, path, pos, stop, acc, fun) do
    case :file.pread(io, pos, min(@chunk_size, stop - pos)) do
      {:ok, data} ->
        case fun.(data, acc) do
          {:ok, acc} -> pread_loop(io, path, pos + byte_size(data), stop, acc, fun)
          {:error, _} = error -> error
        end

      :eof ->
        {:ok, acc}

      {:error, reason} ->
        {:error, Error.from_posix(reason, path)}
    end
  end

  defp open(path) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, io} -> {:ok, io}
      {:error, reason} -> {:error, Error.from_posix(reason, path)}
    end
  end

  # Mirrors Library.Scanner: follows symlinks, skips the trash directory.
  defp walk(root, dir, acc) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.reduce(names, acc, fn name, acc ->
          path = Path.join(dir, name)

          case File.stat(path, time: :posix) do
            {:ok, %File.Stat{type: :directory}} ->
              if name == Mydia.Library.TrashStore.dir_name(), do: acc, else: walk(root, path, acc)

            {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} ->
              entry = %Entry{
                relative_path: Path.relative_to(path, root),
                size: size,
                mtime: DateTime.from_unix!(mtime)
              }

              [entry | acc]

            _ ->
              acc
          end
        end)

      {:error, _} ->
        acc
    end
  end
end
