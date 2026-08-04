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

  # One malformed torrent must not abort the whole DownloadMonitor pass. Before
  # this isolation, a raise here killed ExternalTorrents.refresh/0 and
  # stuck-download detection on every run, and the torrent stayed in the client
  # so the job failed permanently.
  describe "per-torrent exception isolation" do
    test "an exception during processing is contained instead of propagating" do
      insert(:media_item, %{type: "movie", title: "The Matrix", year: 1999, monitored: true})

      # Matches the library, so processing reaches create_download_record/3,
      # which reads torrent.client_name. Dropping that key raises a KeyError
      # deep in the call, which is what the rescue must contain.
      malformed =
        "The.Matrix.1999.1080p.BluRay.x264-GROUP"
        |> torrent()
        |> Map.delete(:client_name)

      assert {:error, :match_exception} =
               UntrackedMatcher.safe_process_untracked_torrent(malformed)
    end

    test "a torrent that is not a map is contained rather than raising in the rescue" do
      # The rescue describes the torrent it failed on. If it reached for those
      # keys with Map.get/2 it would raise BadMapError here and propagate,
      # defeating the isolation.
      assert {:error, :match_exception} = UntrackedMatcher.safe_process_untracked_torrent(nil)
    end

    test "a well-formed torrent still succeeds through the same entry point" do
      movie =
        insert(:media_item, %{type: "movie", title: "The Matrix", year: 1999, monitored: true})

      assert {:ok, download} =
               UntrackedMatcher.safe_process_untracked_torrent(
                 torrent("The.Matrix.1999.1080p.BluRay.x264-GROUP")
               )

      assert download.media_item_id == movie.id
    end
  end
end
