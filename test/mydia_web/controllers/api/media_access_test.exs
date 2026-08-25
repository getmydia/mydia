defmodule MydiaWeb.Api.MediaAccessTest do
  use MydiaWeb.ConnCase, async: false

  import Ecto.Query
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Accounts.Scope
  alias Mydia.Library.GeneratedMedia
  alias Mydia.Library.MediaFile
  alias Mydia.Media
  alias Mydia.Media.MediaItem
  alias Mydia.Metadata.Structs.MediaMetadata
  alias Mydia.Repo

  defp restricted_conn(conn) do
    log_in_user(conn, restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]}))
  end

  defp adult_movie do
    {:ok, item} =
      Media.create_media_item(
        Scope.system(),
        %{
          type: "movie",
          title: "Restricted Movie",
          year: 2024,
          metadata: %MediaMetadata{
            provider_id: "1",
            provider: :metadata_relay,
            media_type: :movie,
            content_rating: "R"
          }
        },
        skip_episode_refresh: true
      )

    Repo.update_all(from(m in MediaItem, where: m.id == ^item.id), set: [category: "movie"])
    Repo.get!(MediaItem, item.id)
  end

  defp adult_show_with_episode do
    {:ok, show} =
      Media.create_media_item(
        Scope.system(),
        %{
          type: "tv_show",
          title: "Restricted Show",
          year: 2024,
          metadata: %MediaMetadata{
            provider_id: "2",
            provider: :metadata_relay,
            media_type: :tv,
            content_rating: "TV-MA"
          }
        },
        skip_episode_refresh: true
      )

    Repo.update_all(from(m in MediaItem, where: m.id == ^show.id), set: [category: "tv_show"])

    {:ok, episode} =
      Media.create_episode(%{
        media_item_id: show.id,
        season_number: 1,
        episode_number: 1,
        title: "Pilot"
      })

    {Repo.get!(MediaItem, show.id), episode}
  end

  # Writes real bytes at the file's resolved on-disk path. Without this, a
  # request for a media_file fixture 404s for the unrelated reason that
  # nothing exists on disk, which would make the "not found" assertions below
  # pass whether or not the access guard runs at all.
  defp write_to_disk(%MediaFile{} = file) do
    file = Repo.preload(file, :library_path)
    absolute_path = MediaFile.absolute_path(file)
    File.mkdir_p!(Path.dirname(absolute_path))
    File.write!(absolute_path, :crypto.strong_rand_bytes(1024))
    file
  end

  test "streaming a restricted movie by media item id is not found", %{conn: conn} do
    movie = adult_movie()

    conn = conn |> restricted_conn() |> get(~p"/api/v1/stream/movie/#{movie.id}")

    assert response(conn, 404)
  end

  test "streaming a restricted episode by episode id is not found", %{conn: conn} do
    {_show, episode} = adult_show_with_episode()

    conn = conn |> restricted_conn() |> get(~p"/api/v1/stream/episode/#{episode.id}")

    assert response(conn, 404)
  end

  test "streaming a restricted episode's file by file id is not found", %{conn: conn} do
    {_show, episode} = adult_show_with_episode()

    file =
      media_file_fixture(%{episode_id: episode.id})
      |> tap(fn f ->
        # A TV media_file reaches its show only through episode_id. Asserting
        # media_item_id is NULL here is the point of this test: a check written
        # against that column alone lets every episode through.
        assert Repo.get!(MediaFile, f.id).media_item_id == nil
      end)
      |> write_to_disk()

    conn = conn |> restricted_conn() |> get(~p"/api/v1/stream/file/#{file.id}")

    assert response(conn, 404)
  end

  test "thumbnails for a restricted movie are not found", %{conn: conn} do
    movie = adult_movie()
    {:ok, checksum} = GeneratedMedia.store(:vtt, "WEBVTT\n\n")
    file = media_file_fixture(%{media_item_id: movie.id, vtt_blob: checksum})

    conn = conn |> restricted_conn() |> get(~p"/api/v1/media/#{file.id}/thumbnails.vtt")

    assert response(conn, 404)
  end

  test "an unrestricted user still reaches the same movie", %{conn: conn} do
    movie = adult_movie()
    media_file_fixture(%{media_item_id: movie.id}) |> write_to_disk()

    conn = conn |> log_in_user(user_fixture()) |> get(~p"/api/v1/stream/movie/#{movie.id}")

    assert conn.status in [200, 206]
  end
end
