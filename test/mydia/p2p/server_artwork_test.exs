defmodule Mydia.P2p.ServerArtworkTest do
  # Changes the global :generated_media_path env, so it cannot run async.
  use ExUnit.Case, async: false

  alias Mydia.Media.PosterStore
  alias Mydia.P2p.FileStream
  alias Mydia.Streaming.SessionFiles

  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0::64>>

  setup do
    dir = Path.join(System.tmp_dir!(), "p2p_artwork_#{System.unique_integer([:positive])}")
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

  test "a stored poster resolves to its file" do
    {:ok, "/generated/posters/" <> name} = PosterStore.write(Ecto.UUID.generate(), @png)
    assert {:ok, path} = FileStream.resolve_artwork("artwork:" <> name)
    assert File.read!(path) == @png
  end

  test "anything else is not found" do
    for id <- [
          "artwork:../avatars/avatar-1.png",
          "artwork:avatar-1.png",
          "artwork:x-0123abcd.gif",
          "artwork:#{Ecto.UUID.generate()}-0123abcd.png",
          "artwork:"
        ] do
      assert FileStream.resolve_artwork(id) == {:error, :not_found}
    end
  end

  test "image files get image content types" do
    assert SessionFiles.content_type("a-0123abcd.jpg") == "image/jpeg"
    assert SessionFiles.content_type("a-0123abcd.png") == "image/png"
    assert SessionFiles.content_type("a-0123abcd.webp") == "image/webp"
  end
end
