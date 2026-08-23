defmodule Mydia.Subtitles.ScoringTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.MediaFile
  alias Mydia.Subtitles.Scoring

  # Carries a DTS token so the release parser reports an audio value. Without
  # it the name parses to audio: nil, and two nils never count as a match, so
  # the "identical name" and "ordering" tests below could never reach a full
  # release-block score.
  @reference_name "The.Matrix.1999.1080p.BluRay.DTS.x264-AMIABLE.mkv"

  # `library_path: nil` matters. Left at its struct default the association is
  # `%Ecto.Association.NotLoaded{}`, which `MediaFile.absolute_path/1` answers
  # with a Logger.warning on every single call before returning nil. An explicit
  # nil takes the silent catch-all clause instead, and `display_path/1` still
  # falls back to `relative_path` either way.
  defp reference(name \\ @reference_name, attrs \\ %{}) do
    base = %MediaFile{relative_path: name, library_path: nil}

    Scoring.build_reference(struct(base, attrs))
  end

  defp points(result, ref, key) do
    {_total, factors} = Scoring.score(result, %{imdb_id: "0133093"}, ref)
    Enum.find(factors, &(&1.key == key)).points
  end

  defp candidate(file_name), do: %{file_id: 1, language: "en", file_name: file_name}

  describe "release factors" do
    test "an identical release name scores the full release block" do
      {total, _factors} =
        Scoring.score(
          candidate("The.Matrix.1999.1080p.BluRay.DTS.x264-AMIABLE"),
          %{imdb_id: "0133093"},
          reference()
        )

      assert total == 100
    end

    # The very common bare naming carries no audio token, so both sides parse
    # to audio: nil and the audio factor can never fire. This locks in the
    # resulting 97 ceiling: it is what makes the badge threshold in
    # `SubtitleModal.score_badge_class/1` 95 rather than 100, and it should
    # break loudly if a future change to the weights or the threshold quietly
    # drifts the common case.
    test "a release name with no audio token on either side totals 97, not 100" do
      {total, factors} =
        Scoring.score(
          candidate("The.Matrix.1999.1080p.BluRay.x264-AMIABLE"),
          %{imdb_id: "0133093"},
          reference("The.Matrix.1999.1080p.BluRay.x264-AMIABLE.mkv")
        )

      assert total == 97

      audio = Enum.find(factors, &(&1.key == :audio))
      assert audio.points == 0
      refute audio.matched
    end

    test "release group awards 20 when it matches" do
      assert points(
               candidate("The.Matrix.1999.1080p.BluRay.x264-AMIABLE"),
               reference(),
               :release_group
             ) == 20
    end

    test "release group awards 0 when it differs" do
      assert points(
               candidate("The.Matrix.1999.1080p.BluRay.x264-SPARKS"),
               reference(),
               :release_group
             ) == 0
    end

    test "source awards 12 when it matches" do
      assert points(candidate("The.Matrix.1999.1080p.BluRay.x264-SPARKS"), reference(), :source) ==
               12
    end

    test "source awards 0 when it differs" do
      assert points(candidate("The.Matrix.1999.720p.WEB-DL"), reference(), :source) == 0
    end

    test "resolution awards 10 when it matches" do
      assert points(
               candidate("The.Matrix.1999.1080p.BluRay.x264-SPARKS"),
               reference(),
               :resolution
             ) == 10
    end

    test "codec awards 5 when it matches" do
      assert points(candidate("The.Matrix.1999.1080p.BluRay.x264-SPARKS"), reference(), :codec) ==
               5
    end

    test "audio awards 3 when it matches" do
      ref = reference("Show.S01E03.2160p.UHD.BluRay.x265.DTS-HD.MA.5.1-GROUP.mkv")

      assert points(candidate("Show.S01E03.2160p.BluRay.x265.DTS-HD.MA.5.1-OTHER"), ref, :audio) ==
               3
    end

    # Two nils are an absence of information, not agreement. Scoring them as a
    # match would hand free points to every unparseable pair.
    test "a factor nil on both sides awards 0 and is not marked matched" do
      {_total, factors} =
        Scoring.score(
          candidate("Matrix (1999)"),
          %{imdb_id: "0133093"},
          reference("Matrix (1999)")
        )

      group = Enum.find(factors, &(&1.key == :release_group))
      assert group.points == 0
      refute group.matched
    end
  end

  describe "reference fallback to analyzed columns" do
    test "fills resolution and codec from the media file when the name says nothing" do
      ref = reference("S01E03.mkv", %{resolution: "1080p", codec: "H.264"})

      assert ref.resolution == "1080p (Full HD)"
      assert ref.codec == "H.264/AVC"
    end

    test "folds 4K from the analyzer into the parser's canonical form" do
      assert reference("S01E03.mkv", %{resolution: "4K"}).resolution == "2160p (4K)"
    end

    # The name is the better source when it has one, since it describes the
    # release rather than the decoded stream.
    test "the parsed name wins over the analyzed column" do
      ref = reference(@reference_name, %{resolution: "720p"})

      assert ref.resolution == "1080p (Full HD)"
    end

    test "a nil media file yields a nil reference" do
      assert Scoring.build_reference(nil) == nil
    end
  end

  describe "degenerate inputs" do
    test "a nil file_name scores the release block at 0 without raising" do
      {total, _factors} =
        Scoring.score(%{file_id: 1, language: "en"}, %{imdb_id: "0133093"}, reference())

      assert total == 50
    end

    test "an empty file_name scores the release block at 0" do
      {total, _factors} = Scoring.score(candidate(""), %{imdb_id: "0133093"}, reference())

      assert total == 50
    end

    test "a nil reference scores the release block at 0" do
      {total, _factors} =
        Scoring.score(
          candidate("The.Matrix.1999.1080p.BluRay.x264-AMIABLE"),
          %{imdb_id: "0133093"},
          nil
        )

      assert total == 50
    end
  end

  describe "carried-over terms" do
    test "a hash match awards 100 only when the search supplied a hash" do
      result = %{file_id: 1, language: "en", moviehash_match: true}

      {with_hash, _} = Scoring.score(result, %{file_hash: "abc"}, nil)
      {without_hash, _} = Scoring.score(result, %{}, nil)

      assert with_hash == 100
      assert without_hash == 0
    end

    test "rating and popularity carry their previous weights" do
      result = %{file_id: 1, language: "en", rating: 8.0, download_count: 5_000}

      {total, _} = Scoring.score(result, %{imdb_id: "0133093"}, nil)

      # 50 metadata + round(8.0 * 20 / 10) + round(log10(5000) * 10)
      assert total == 50 + 16 + 37
    end
  end

  describe "ordering" do
    test "the four worked-example candidates rank as the spec states" do
      ref = reference()
      params = %{imdb_id: "0133093"}

      totals =
        for name <- [
              "The.Matrix.1999.1080p.BluRay.DTS.x264-AMIABLE",
              "The.Matrix.1999.1080p.BluRay.DTS.x264-SPARKS",
              "The.Matrix.1999.720p.WEB-DL",
              "Matrix (1999)"
            ] do
          {total, _} = Scoring.score(candidate(name), params, ref)
          total
        end

      assert totals == [100, 80, 50, 50]
    end
  end
end
