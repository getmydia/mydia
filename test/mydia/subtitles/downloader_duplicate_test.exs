defmodule Mydia.Subtitles.DownloaderDuplicateTest do
  use Mydia.DataCase, async: true

  alias Mydia.MediaFixtures
  alias Mydia.Repo
  alias Mydia.Subtitles.Subtitle

  defp insert_subtitle(media_file_id, hash) do
    %Subtitle{}
    |> Subtitle.changeset(%{
      media_file_id: media_file_id,
      language: "en",
      format: "srt",
      subtitle_hash: hash,
      file_path: "/tmp/whatever.srt",
      provider: "relay"
    })
    |> Repo.insert!()
  end

  test "the same subtitle hash on two media files is not a duplicate" do
    movie = MediaFixtures.media_item_fixture(%{type: "movie"})
    file_1080 = MediaFixtures.media_file_fixture(%{media_item_id: movie.id})
    file_2160 = MediaFixtures.media_file_fixture(%{media_item_id: movie.id})

    insert_subtitle(file_1080.id, "shared-hash")

    # The 4K file has no subtitle yet, so a lookup scoped to it must find nothing.
    assert Repo.get_by(Subtitle, media_file_id: file_2160.id, subtitle_hash: "shared-hash") == nil
    assert Repo.get_by(Subtitle, subtitle_hash: "shared-hash") != nil
  end

  test "the same subtitle hash on the same media file is a duplicate" do
    media_file = MediaFixtures.media_file_fixture()
    existing = insert_subtitle(media_file.id, "same-hash")

    found = Repo.get_by(Subtitle, media_file_id: media_file.id, subtitle_hash: "same-hash")
    assert found.id == existing.id
  end
end
