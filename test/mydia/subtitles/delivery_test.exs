defmodule Mydia.Subtitles.DeliveryTest do
  use Mydia.DataCase, async: false

  alias Mydia.MediaFixtures
  alias Mydia.Repo
  alias Mydia.Subtitles.Delivery
  alias Mydia.Subtitles.Subtitle
  alias Mydia.Subtitles.TrackSettings

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

    test "is returned unshifted when no offset is stored", %{
      media_file: media_file,
      subtitle: subtitle
    } do
      assert {:ok, body} = Delivery.content(media_file, subtitle.id, "srt")
      assert body =~ "00:00:01,000 --> 00:00:04,000"
    end

    test "is shifted by the stored offset", %{media_file: media_file, subtitle: subtitle} do
      {:ok, _} = TrackSettings.set_offset(media_file.id, subtitle.id, 3_000)

      assert {:ok, body} = Delivery.content(media_file, subtitle.id, "srt")
      assert body =~ "00:00:04,000 --> 00:00:07,000"
    end

    test "changing the offset changes what is delivered", %{
      media_file: media_file,
      subtitle: subtitle
    } do
      {:ok, _} = TrackSettings.set_offset(media_file.id, subtitle.id, 1_000)
      {:ok, first} = Delivery.content(media_file, subtitle.id, "srt")

      {:ok, _} = TrackSettings.set_offset(media_file.id, subtitle.id, 5_000)
      {:ok, second} = Delivery.content(media_file, subtitle.id, "srt")

      refute first == second
      assert second =~ "00:00:06,000 --> 00:00:09,000"
    end
  end

  describe "content/3 for an embedded track" do
    test "the cache path varies with the offset so a changed offset is not served stale", %{
      media_file: media_file
    } do
      stat = %File.Stat{mtime: {{2026, 1, 1}, {0, 0, 0}}, size: 1_000}

      without = Delivery.cache_path(media_file.id, 3, stat, "vtt", 0)
      with_offset = Delivery.cache_path(media_file.id, 3, stat, "vtt", 2_500)

      refute without == with_offset
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
