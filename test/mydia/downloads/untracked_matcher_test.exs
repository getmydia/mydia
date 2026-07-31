defmodule Mydia.Downloads.UntrackedMatcherTest do
  @moduledoc """
  U4: untracked torrents flow through ReleaseIntake (validate + parse) and the
  reworked matcher. Exercises the parse/match/route decision and the metadata
  sourced from the ParsedFileInfo / Quality shapes.
  """
  use Mydia.DataCase, async: true

  alias Mydia.Downloads.UntrackedMatcher
  alias Mydia.Repo

  import Mydia.Factory

  defp torrent(name, overrides \\ %{}) do
    Map.merge(
      %{
        name: name,
        id: "hash-#{System.unique_integer([:positive])}",
        client_name: "qbittorrent",
        size: 1_000_000,
        seeders: 10,
        leechers: 1,
        save_path: "/downloads"
      },
      overrides
    )
  end

  describe "matched torrent" do
    test "creates a tracked download with quality sourced from the Quality struct" do
      movie =
        insert(:media_item, %{type: "movie", title: "The Matrix", year: 1999, monitored: true})

      assert {:ok, download} =
               UntrackedMatcher.process_untracked_torrent(
                 torrent("The.Matrix.1999.1080p.BluRay.x264-GROUP")
               )

      assert download.media_item_id == movie.id
      # Quality came from the Quality struct (resolution), not a flat string field.
      assert download.metadata["quality"] == "1080p" or download.metadata[:quality] == "1080p"
    end
  end

  # A torrent with no library match is not Mydia's problem to record. It is
  # surfaced by Mydia.Downloads.ExternalTorrents, which derives it from the
  # client on every scan, so nothing is written here.
  describe "no library match" do
    test "reports no match instead of creating an unmatched download" do
      assert {:error, :no_library_match} =
               UntrackedMatcher.process_untracked_torrent(
                 torrent("Some.Unknown.Movie.2021.1080p.BluRay.x264-GROUP")
               )

      assert Repo.aggregate(Mydia.Downloads.Download, :count) == 0
    end
  end

  describe "validator-rejected torrent (AE1)" do
    test "reports no match and writes nothing" do
      assert {:error, :no_library_match} =
               UntrackedMatcher.process_untracked_torrent(
                 torrent("From.S04E05.1080p.WEB.h264-ETHEL.exe")
               )

      assert Repo.aggregate(Mydia.Downloads.Download, :count) == 0
    end
  end
end
