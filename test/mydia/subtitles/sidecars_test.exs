defmodule Mydia.Subtitles.SidecarsTest do
  use Mydia.DataCase, async: true

  alias Mydia.Subtitles.Sidecars

  describe "parse_filename/2" do
    test "a bare sidecar has an unknown language" do
      assert %{language: "und", forced: false, hearing_impaired: false} =
               Sidecars.parse_filename("Movie.srt", "Movie")
    end

    test "reads an ISO 639-1 code" do
      assert %{language: "en"} = Sidecars.parse_filename("Movie.en.srt", "Movie")
    end

    test "reads an ISO 639-2 code" do
      assert %{language: "en"} = Sidecars.parse_filename("Movie.eng.srt", "Movie")
    end

    test "reads an English language name" do
      assert %{language: "en"} = Sidecars.parse_filename("Movie.English.srt", "Movie")
    end

    test "is case insensitive" do
      assert %{language: "en"} = Sidecars.parse_filename("Movie.EN.srt", "Movie")
      assert %{language: "pt"} = Sidecars.parse_filename("Movie.Portuguese.srt", "Movie")
    end

    test "matches the media basename against the sidecar case-insensitively" do
      assert %{language: "en"} = Sidecars.parse_filename("MOVIE.EN.SRT", "Movie")
    end

    test "reads the forced flag" do
      assert %{language: "en", forced: true} =
               Sidecars.parse_filename("Movie.en.forced.srt", "Movie")
    end

    test "reads each hearing-impaired spelling" do
      for tag <- ~w(sdh cc) do
        assert %{language: "en", hearing_impaired: true} =
                 Sidecars.parse_filename("Movie.en.#{tag}.srt", "Movie")
      end
    end

    test "hi reads as Hindi, not as hearing impaired" do
      assert %{language: "hi", hearing_impaired: false} =
               Sidecars.parse_filename("Movie.hi.srt", "Movie")
    end

    test "a flag with no language still parses" do
      assert %{language: "und", forced: true} =
               Sidecars.parse_filename("Movie.forced.srt", "Movie")
    end

    test "ignores an unrecognized tag rather than treating it as a language" do
      assert %{language: "en"} = Sidecars.parse_filename("Movie.HDR.en.srt", "Movie")
    end

    test "handles a media basename containing dots" do
      assert %{language: "es"} =
               Sidecars.parse_filename(
                 "Some.Movie.2019.1080p.es.srt",
                 "Some.Movie.2019.1080p"
               )
    end

    test "a media basename that is a prefix of a longer basename does not swallow a tag" do
      assert %{language: "en"} =
               Sidecars.parse_filename("Movie.Sequel.en.srt", "Movie")
    end

    test "a sidecar that is exactly the basename plus extension has no tags" do
      assert %{language: "und", forced: false, hearing_impaired: false} =
               Sidecars.parse_filename("Some.Movie.2019.1080p.srt", "Some.Movie.2019.1080p")
    end
  end
end
