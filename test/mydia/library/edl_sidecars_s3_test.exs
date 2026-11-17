defmodule Mydia.Library.EdlSidecarsS3Test do
  use Mydia.DataCase, async: false

  @moduletag :s3

  import Mydia.MediaFixtures

  alias Mydia.Library.EdlSidecars
  alias Mydia.Library.MediaFile
  alias Mydia.S3Helpers

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

    %{loc: loc, media: Repo.preload(Repo.get!(MediaFile, media.id), :library_path)}
  end

  test "adopts an EDL sidecar object", %{loc: loc, media: media} do
    S3Helpers.put_object!(loc, "Invented Film (2031)/film.edl", "612.48\t735.10\t3\n")

    assert %{adopted: 1, errors: []} = EdlSidecars.reconcile_all([media])

    assert [segment] = Repo.preload(media, :segments).segments
    assert {segment.start_ms, segment.end_ms} == {612_480, 735_100}
  end
end
