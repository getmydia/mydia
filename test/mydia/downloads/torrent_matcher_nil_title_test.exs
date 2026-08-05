defmodule Mydia.Downloads.TorrentMatcherNilTitleTest do
  @moduledoc """
  A release can parse to a movie with no title (see
  `ReleaseParser.infer_media_type/4`, which returns `:movie` on a year or
  quality token without consulting the title). Matching must score such a
  release as a non-match rather than raising, because a raise here aborts the
  entire `Mydia.Jobs.DownloadMonitor` pass.
  """
  use Mydia.DataCase, async: true

  alias Mydia.Downloads.TorrentMatcher

  import Mydia.Factory

  describe "find_match/2 with a nil title" do
    setup do
      movie = insert(:media_item, %{type: "movie", title: "The Matrix", year: 1999})
      %{movie: movie}
    end

    test "a titleless movie release returns no match instead of raising" do
      torrent_info = %{type: :movie, title: nil, year: 2019}

      assert {:error, :no_match_found} =
               TorrentMatcher.find_match(torrent_info, monitored_only: false)
    end

    test "a titleless movie release with no year also returns no match" do
      torrent_info = %{type: :movie, title: nil, year: nil}

      assert {:error, :no_match_found} =
               TorrentMatcher.find_match(torrent_info, monitored_only: false)
    end
  end
end
