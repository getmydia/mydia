defmodule Mydia.Subtitles.DownloaderDuplicateTest do
  @moduledoc """
  Change (a): `Downloader.check_duplicate/2` must be scoped to
  `{media_file_id, subtitle_hash}`, not `subtitle_hash` alone. Two rips of the
  same movie (a 1080p and a 4K) can legitimately share a `subtitle_hash` when
  a provider matches them to the same underlying subtitle file. A lookup
  scoped to `subtitle_hash` alone would silently hand the second file the
  first file's row, and `Delivery.content/3` then rightly refuses to serve it
  as `:unauthorized`.

  Per the human review that overruled the original brief, this exercises the
  real download path end to end through `Mydia.Subtitles.download_subtitle/3`
  (stubbing only the relay's HTTP endpoints via Bypass), rather than
  asserting on `Repo.get_by` queries directly -- asserting on the ORM's query
  shape proves nothing about whether the Downloader actually uses it.

  This also happens to prove out the migration that must accompany the
  query-level fix: the original schema put a *global* unique index on
  `subtitle_hash` alone (priv/repo/migrations/20251116022802), which would
  reject the second file's insert even if the lookup were scoped correctly.
  Both halves need to move together for a real second row to appear.
  """
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures

  alias Mydia.Repo
  alias Mydia.Subtitles
  alias Mydia.Subtitles.Subtitle

  @srt_content "1\r\n00:00:01,000 --> 00:00:05,000\r\nHello there\r\n\r\n"

  setup do
    bypass = Bypass.open()
    original = Application.get_env(:mydia, :subtitle_relay_url)

    Application.put_env(:mydia, :subtitle_relay_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.put_env(:mydia, :subtitle_relay_url, original) end)

    %{bypass: bypass}
  end

  defp subtitle_info(overrides \\ %{}) do
    Map.merge(
      %{
        file_id: 12_345,
        language: "en",
        format: "srt",
        subtitle_hash: "shared-hash",
        rating: 8.0,
        download_count: 10,
        hearing_impaired: false
      },
      overrides
    )
  end

  # Any number of calls, unverified count -- used where the test genuinely
  # expects the provider to be hit more than once (once per media file).
  defp stub_download(bypass, file_id, content) do
    Bypass.stub(bypass, "GET", "/api/v1/subtitles/download-url/#{file_id}", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "download_url" => "http://localhost:#{bypass.port}/files/#{file_id}.srt"
        })
      )
    end)

    Bypass.stub(bypass, "GET", "/files/#{file_id}.srt", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.resp(200, content)
    end)
  end

  # Exactly one call each -- used where the test asserts the provider must
  # NOT be hit a second time (a genuine duplicate short-circuits first).
  defp expect_download_once(bypass, file_id, content) do
    Bypass.expect_once(bypass, "GET", "/api/v1/subtitles/download-url/#{file_id}", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "download_url" => "http://localhost:#{bypass.port}/files/#{file_id}.srt"
        })
      )
    end)

    Bypass.expect_once(bypass, "GET", "/files/#{file_id}.srt", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.resp(200, content)
    end)
  end

  test "downloading a hash already present on file A creates a new row for file B", %{
    bypass: bypass
  } do
    movie = media_item_fixture(%{type: "movie"})
    file_1080 = media_file_fixture(%{media_item_id: movie.id})
    file_2160 = media_file_fixture(%{media_item_id: movie.id})

    stub_download(bypass, 12_345, @srt_content)

    assert {:ok, subtitle_a} = Subtitles.download_subtitle(subtitle_info(), file_1080.id)
    assert {:ok, subtitle_b} = Subtitles.download_subtitle(subtitle_info(), file_2160.id)

    refute subtitle_b.id == subtitle_a.id
    assert subtitle_a.media_file_id == file_1080.id
    assert subtitle_b.media_file_id == file_2160.id
    assert subtitle_a.subtitle_hash == "shared-hash"
    assert subtitle_b.subtitle_hash == "shared-hash"

    assert Repo.get_by(Subtitle, media_file_id: file_2160.id, subtitle_hash: "shared-hash").id ==
             subtitle_b.id

    assert Repo.aggregate(Subtitle, :count) == 2
  end

  test "downloading the same hash for the same file again returns the existing row, without a second provider call",
       %{bypass: bypass} do
    media_file = media_file_fixture()

    expect_download_once(bypass, 12_345, @srt_content)

    assert {:ok, first} = Subtitles.download_subtitle(subtitle_info(), media_file.id)
    assert {:ok, second} = Subtitles.download_subtitle(subtitle_info(), media_file.id)

    assert second.id == first.id
    assert Repo.aggregate(Subtitle, :count) == 1
  end
end
