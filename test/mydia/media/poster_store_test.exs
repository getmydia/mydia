defmodule Mydia.Media.PosterStoreTest do
  # Changes the global :generated_media_path env, so it cannot run async.
  use ExUnit.Case, async: false

  alias Mydia.Media.PosterStore

  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0::64>>
  @jpg <<0xFF, 0xD8, 0xFF, 0xE0, 0::64>>
  @webp "RIFF" <> <<0::32>> <> "WEBPVP8 " <> <<0::64>>

  setup do
    dir = Path.join(System.tmp_dir!(), "poster_store_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = Application.fetch_env(:mydia, :generated_media_path)
    Application.put_env(:mydia, :generated_media_path, dir)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:mydia, :generated_media_path, value)
        :error -> Application.delete_env(:mydia, :generated_media_path)
      end

      File.rm_rf!(dir)
    end)

    :ok
  end

  test "detect_format reads magic bytes, not names" do
    assert PosterStore.detect_format(@png) == {:ok, "png"}
    assert PosterStore.detect_format(@jpg) == {:ok, "jpg"}
    assert PosterStore.detect_format(@webp) == {:ok, "webp"}
    assert PosterStore.detect_format("<html>not an image</html>") == {:error, :unsupported_format}
  end

  test "write names the file <id>-<sha8>.<ext> and rejects oversize" do
    id = Ecto.UUID.generate()
    {:ok, "/generated/posters/" <> name} = PosterStore.write(id, @png)
    assert name =~ ~r/^#{id}-[0-9a-f]{8}\.png$/
    assert File.exists?(Path.join(PosterStore.storage_dir(), name))
    assert PosterStore.write(id, @png <> :binary.copy(<<0>>, 10_000_000)) == {:error, :too_large}
  end

  test "write rejects non-images" do
    assert PosterStore.write(Ecto.UUID.generate(), "<html>") == {:error, :unsupported_format}
  end

  test "delete removes a hosted file" do
    {:ok, url} = PosterStore.write(Ecto.UUID.generate(), @png)
    assert PosterStore.hosted?(url)
    assert PosterStore.delete(url) == :ok
    refute File.exists?(Path.join(PosterStore.storage_dir(), Path.basename(url)))
  end

  test "delete ignores paths outside the posters dir" do
    assert PosterStore.delete("/generated/avatars/avatar-1.png") == :ok
    assert PosterStore.delete("/abc.jpg") == :ok
    assert PosterStore.delete(nil) == :ok
    refute PosterStore.hosted?("/abc.jpg")
    refute PosterStore.hosted?(nil)
  end

  test "writing bytes that are already stored leaves the file alone" do
    id = Ecto.UUID.generate()
    {:ok, url} = PosterStore.write(id, @png)
    path = Path.join(PosterStore.storage_dir(), Path.basename(url))

    # Names are content-addressed, so a file under this name already holds
    # these bytes. A rewrite would truncate a file a client may be reading.
    File.write!(path, "marker")
    assert PosterStore.write(id, @png) == {:ok, url}
    assert File.read!(path) == "marker"
  end

  test "path_for refuses a name with a trailing newline" do
    id = Ecto.UUID.generate()
    {:ok, url} = PosterStore.write(id, @png)
    name = Path.basename(url) <> "\n"
    File.write!(Path.join(PosterStore.storage_dir(), name), @png)

    assert PosterStore.path_for(name) == {:error, :not_found}
  end

  test "path_for only serves well-formed existing filenames" do
    id = Ecto.UUID.generate()
    {:ok, url} = PosterStore.write(id, @png)
    name = Path.basename(url)
    assert {:ok, path} = PosterStore.path_for(name)
    assert File.exists?(path)
    assert PosterStore.path_for("../avatars/x.png") == {:error, :not_found}
    assert PosterStore.path_for("avatar-1.png") == {:error, :not_found}
    assert PosterStore.path_for("#{id}-deadbeef.png") == {:error, :not_found}
  end
end
