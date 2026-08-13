defmodule Mydia.SubtitlesTest do
  use ExUnit.Case, async: true

  describe "auto-download confidence" do
    # SubDL cannot report a hash match, so a metadata match plus a decent
    # rating and download count has to be enough to clear the bar. If it is
    # not, the auto_download option is dead code.
    test "a metadata-only match can reach the auto-download threshold" do
      results =
        Mydia.Subtitles.score_results(
          [
            %{
              file_id: 1,
              language: "en",
              rating: 8.0,
              download_count: 5_000,
              moviehash_match: false
            }
          ],
          %{languages: "en", imdb_id: "0133093"}
        )

      assert [%{score: score}] = results
      assert score >= Mydia.Subtitles.high_confidence_threshold()
    end
  end
end
