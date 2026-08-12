defmodule Mydia.Subtitles.DeliveryTest do
  use Mydia.DataCase, async: false

  alias Mydia.MediaFixtures
  alias Mydia.Repo
  alias Mydia.Subtitles.Delivery
  alias Mydia.Subtitles.Subtitle

  @srt """
  1
  00:00:01,000 --> 00:00:04,000
  Hello there.
  """

  setup do
    media_file = MediaFixtures.media_file_fixture() |> Repo.preload(:library_path)
    {:ok, media_file: media_file}
  end

  describe "content/3 for an external sidecar" do
    setup %{media_file: media_file} do
      dir =
        Path.join(System.tmp_dir!(), "mydia-delivery-test-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      path = Path.join(dir, "sub.en.srt")
      File.write!(path, @srt)
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, subtitle} =
        %Subtitle{}
        |> Subtitle.changeset(%{
          media_file_id: media_file.id,
          language: "en",
          format: "srt",
          subtitle_hash: "hash-#{System.unique_integer([:positive])}",
          file_path: path,
          provider: "relay"
        })
        |> Repo.insert()

      {:ok, subtitle: subtitle}
    end

    test "converts to the requested format", %{media_file: media_file, subtitle: subtitle} do
      assert {:ok, vtt} = Delivery.content(media_file, subtitle.id, "vtt")
      assert String.starts_with?(vtt, "WEBVTT")
      assert vtt =~ "00:00:01.000 --> 00:00:04.000"
    end

    test "returns the stored content when the format already matches", %{
      media_file: media_file,
      subtitle: subtitle
    } do
      assert {:ok, srt} = Delivery.content(media_file, subtitle.id, "srt")
      assert srt =~ "00:00:01,000 --> 00:00:04,000"
    end

    test "reports a missing file on disk", %{media_file: media_file, subtitle: subtitle} do
      File.rm!(subtitle.file_path)
      assert {:error, :file_not_found} = Delivery.content(media_file, subtitle.id, "vtt")
    end

    test "refuses a subtitle belonging to another media file", %{subtitle: subtitle} do
      other = MediaFixtures.media_file_fixture() |> Repo.preload(:library_path)
      assert {:error, :unauthorized} = Delivery.content(other, subtitle.id, "vtt")
    end

    test "reports an unknown track", %{media_file: media_file} do
      assert {:error, :subtitle_not_found} =
               Delivery.content(media_file, Ecto.UUID.generate(), "vtt")
    end
  end

  describe "content/3 for an image track" do
    test "refuses PGS", %{media_file: media_file} do
      assert {:error, :image_subtitle} = Delivery.content(media_file, {:image, 0}, "vtt")
    end
  end

  describe "content/3 format validation" do
    # The REST controller reads `format` straight off the query string, and it
    # ends up in a cache path and an ffmpeg argument. GraphQL constrains it via
    # an enum; nothing constrains the REST caller.
    test "refuses a format that is not supported", %{media_file: media_file} do
      assert {:error, {:unsupported_format, "exe"}} =
               Delivery.content(media_file, 1, "exe")
    end

    test "refuses a traversal attempt before it reaches a path", %{media_file: media_file} do
      assert {:error, {:unsupported_format, _}} =
               Delivery.content(media_file, 1, "../../etc/passwd")
    end

    # Asserts only that the guard admits them. What happens afterwards is the
    # concern of the sidecar and embedded tests above.
    test "admits every supported format", %{media_file: media_file} do
      for format <- Mydia.Subtitles.Subtitle.supported_formats() do
        refute match?(
                 {:error, {:unsupported_format, _}},
                 Delivery.content(media_file, 1, format)
               )
      end
    end
  end
end
