defmodule Mydia.Subtitles.SidecarsS3Test do
  use Mydia.DataCase, async: false

  @moduletag :s3

  import Mydia.MediaFixtures

  alias Mydia.Library.MediaFile
  alias Mydia.S3Helpers
  alias Mydia.Storage
  alias Mydia.Subtitles
  alias Mydia.Subtitles.Delivery
  alias Mydia.Subtitles.Sidecars

  @srt "1\n00:00:01,000 --> 00:00:02,000\nAn invented line\n"

  setup do
    S3Helpers.ensure_backend_row!()
    {lp, loc} = S3Helpers.library_path!("movies")
    on_exit(fn -> S3Helpers.delete_prefix!(loc) end)
    S3Helpers.put_object!(loc, "Invented Film (2031)/film.mkv", "v")

    media =
      media_file_fixture(%{
        library_path_id: lp.id,
        relative_path: "Invented Film (2031)/film.mkv"
      })

    %{lp: lp, loc: loc, media: Repo.preload(Repo.get!(MediaFile, media.id), :library_path)}
  end

  test "reconcile adopts a sidecar object and reaps it once deleted", %{
    lp: lp,
    loc: loc,
    media: media
  } do
    S3Helpers.put_object!(loc, "Invented Film (2031)/film.en.srt", @srt)

    assert {:ok, _} = Sidecars.reconcile(media)
    assert [subtitle] = Subtitles.list_subtitles(media.id)
    assert subtitle.file_path == Path.join(lp.path, "Invented Film (2031)/film.en.srt")

    assert {:ok, served} = Delivery.content(media, subtitle.id, "srt")
    assert served =~ "An invented line"

    :ok = Storage.delete_path(subtitle.file_path)
    assert {:ok, _} = Sidecars.reconcile(media)
    assert [] = Subtitles.list_subtitles(media.id)
  end

  test "an unreachable listing reaps nothing", %{loc: loc, media: media} do
    S3Helpers.put_object!(loc, "Invented Film (2031)/film.en.srt", @srt)
    assert {:ok, _} = Sidecars.reconcile(media)
    assert [_] = Subtitles.list_subtitles(media.id)

    backend = Mydia.Settings.get_storage_backend_by_name("test")
    {:ok, _} = Mydia.Settings.update_storage_backend(backend, %{endpoint: "http://127.0.0.1:1"})

    on_exit(fn ->
      Mydia.Settings.update_storage_backend(backend, %{endpoint: backend.endpoint})
    end)

    assert {:error, _} = Sidecars.reconcile(media)
    assert [_] = Subtitles.list_subtitles(media.id)
  end

  test "upload writes an exclusive sidecar and a second upload is refused", %{
    loc: loc,
    media: media
  } do
    assert {:ok, subtitle} = Subtitles.upload_subtitle(media, @srt, language: "en")
    assert {:ok, @srt} = Storage.read_path(subtitle.file_path)

    assert {:error, "There is already a subtitle for that language. Delete it first."} =
             Subtitles.upload_subtitle(media, @srt, language: "en")

    assert :ok = Subtitles.delete_subtitle(subtitle.id)
    {:ok, gone} = Storage.source(loc, "Invented Film (2031)/film.en.srt")
    refute Storage.exists?(gone)
  end
end
