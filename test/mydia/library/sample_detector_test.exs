defmodule Mydia.Library.SampleDetectorTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.SampleDetector
  alias Mydia.Library.Structs.ParsedFileInfo
  alias Mydia.Library.Structs.Quality

  describe "detect/1 - folder-based detection" do
    test "detects files in Sample folder" do
      result = SampleDetector.detect("/movies/Avatar/Sample/avatar-sample.mkv")

      assert result.is_sample == true
      assert result.is_trailer == false
      assert result.is_extra == false
      assert result.detection_method == :folder
      assert result.detected_folder == "Sample"
    end

    test "detects files in Samples folder" do
      result = SampleDetector.detect("/movies/Avatar/Samples/test.mkv")

      assert result.is_sample == true
      assert result.detection_method == :folder
      assert result.detected_folder == "Samples"
    end

    test "detects files in Trailers folder" do
      result = SampleDetector.detect("/movies/Avatar/Trailers/official-trailer.mkv")

      assert result.is_trailer == true
      assert result.is_sample == false
      assert result.is_extra == false
      assert result.detection_method == :folder
      assert result.detected_folder == "Trailers"
    end

    test "detects files in Behind The Scenes folder" do
      result = SampleDetector.detect("/movies/Avatar/Behind The Scenes/making-of.mkv")

      assert result.is_extra == true
      assert result.is_sample == false
      assert result.is_trailer == false
      assert result.detection_method == :folder
      assert result.detected_folder == "Behind The Scenes"
    end

    test "detects files in Extras folder" do
      result = SampleDetector.detect("/movies/Avatar/Extras/bonus.mkv")

      assert result.is_extra == true
      assert result.detection_method == :folder
      assert result.detected_folder == "Extras"
    end

    test "detects files in Deleted Scenes folder" do
      result = SampleDetector.detect("/movies/Avatar/Deleted Scenes/cut-scene.mkv")

      assert result.is_extra == true
      assert result.detection_method == :folder
    end

    test "detects files in Featurettes folder" do
      result = SampleDetector.detect("/movies/Avatar/Featurettes/featurette-01.mkv")

      assert result.is_extra == true
      assert result.detection_method == :folder
    end

    test "detects files in Interviews folder" do
      result = SampleDetector.detect("/movies/Avatar/Interviews/director-interview.mkv")

      assert result.is_extra == true
      assert result.detection_method == :folder
    end

    test "folder detection is case-insensitive" do
      # Test various case combinations
      assert SampleDetector.detect("/movies/Avatar/SAMPLE/test.mkv").is_sample == true
      assert SampleDetector.detect("/movies/Avatar/trailers/test.mkv").is_trailer == true
      assert SampleDetector.detect("/movies/Avatar/EXTRAS/test.mkv").is_extra == true
    end
  end

  describe "detect/1 - filename-based detection" do
    test "detects sample files with -sample suffix" do
      result = SampleDetector.detect("/movies/Avatar/avatar-sample.mkv")

      assert result.is_sample == true
      assert result.is_trailer == false
      assert result.detection_method == :filename
      assert result.detected_folder == nil
    end

    test "detects sample files with _sample suffix" do
      result = SampleDetector.detect("/movies/Avatar/avatar_sample.mkv")

      assert result.is_sample == true
      assert result.detection_method == :filename
    end

    test "detects sample files with .sample suffix" do
      result = SampleDetector.detect("/movies/Avatar/avatar.sample.mkv")

      assert result.is_sample == true
      assert result.detection_method == :filename
    end

    test "detects trailer files with -trailer suffix" do
      result = SampleDetector.detect("/movies/Avatar/avatar-trailer.mkv")

      assert result.is_trailer == true
      assert result.is_sample == false
      assert result.detection_method == :filename
    end

    test "detects trailer files with _trailer suffix" do
      result = SampleDetector.detect("/movies/Avatar/avatar_trailer.mkv")

      assert result.is_trailer == true
    end

    test "detects featurette files" do
      result = SampleDetector.detect("/movies/Avatar/avatar-featurette.mkv")

      assert result.is_extra == true
      assert result.detection_method == :filename
    end

    test "detects deleted scenes files" do
      result = SampleDetector.detect("/movies/Avatar/avatar-deleted.mkv")

      assert result.is_extra == true
    end

    test "detects deleted scenes files with suffix" do
      result = SampleDetector.detect("/movies/Avatar/avatar-deleted scenes.mkv")

      assert result.is_extra == true
    end

    test "detects behind the scenes files" do
      result = SampleDetector.detect("/movies/Avatar/avatar-behind the scenes.mkv")

      assert result.is_extra == true
    end

    test "detects interview files" do
      result = SampleDetector.detect("/movies/Avatar/avatar-interview.mkv")

      assert result.is_extra == true
    end

    test "detects bonus content" do
      result = SampleDetector.detect("/movies/Avatar/avatar-bonus.mkv")

      assert result.is_extra == true
    end

    test "detects extra content" do
      result = SampleDetector.detect("/movies/Avatar/avatar-extra.mkv")

      assert result.is_extra == true
    end

    test "does not flag regular movie files" do
      result = SampleDetector.detect("/movies/Avatar/Avatar.2009.1080p.BluRay.x264-GROUP.mkv")

      assert result.is_sample == false
      assert result.is_trailer == false
      assert result.is_extra == false
      assert result.detection_method == nil
    end

    test "does not flag regular TV episode files" do
      result = SampleDetector.detect("/tv/Breaking Bad/Season 01/Breaking.Bad.S01E01.mkv")

      assert result.is_sample == false
      assert result.is_trailer == false
      assert result.is_extra == false
    end

    test "filename detection is case-insensitive" do
      assert SampleDetector.detect("/movies/test/Movie-SAMPLE.mkv").is_sample == true
      assert SampleDetector.detect("/movies/test/Movie-TRAILER.mkv").is_trailer == true
      assert SampleDetector.detect("/movies/test/Movie-FEATURETTE.mkv").is_extra == true
    end
  end

  describe "detect/1 - folder takes priority" do
    test "folder detection overrides filename detection" do
      # A file named with -trailer in a Sample folder should be detected as sample
      result = SampleDetector.detect("/movies/Avatar/Sample/trailer.mkv")

      assert result.is_sample == true
      assert result.is_trailer == false
      assert result.detection_method == :folder
    end
  end

  describe "sample_by_duration?/2" do
    test "returns false for nil duration" do
      assert SampleDetector.sample_by_duration?(nil) == false
    end

    test "returns true for zero duration" do
      assert SampleDetector.sample_by_duration?(0.0) == true
    end

    test "returns true for negative duration" do
      assert SampleDetector.sample_by_duration?(-1.0) == true
    end

    test "returns true for very short duration (movie)" do
      # 45 seconds is too short for a movie (min 600s)
      assert SampleDetector.sample_by_duration?(45.0, expected_type: :movie) == true
    end

    test "returns false for normal movie duration" do
      # 2 hours is fine for a movie
      assert SampleDetector.sample_by_duration?(7200.0, expected_type: :movie) == false
    end

    test "returns true for short TV episode with no expected duration" do
      # 60 seconds - shorter than default 300s threshold
      assert SampleDetector.sample_by_duration?(60.0, expected_type: :tv_show) == true
    end

    test "returns false for normal TV episode" do
      # 42 minutes is fine for TV
      assert SampleDetector.sample_by_duration?(2520.0, expected_type: :tv_show) == false
    end

    test "uses appropriate threshold for anime shorts" do
      # Anime short expected to be 3 minutes, 10 seconds is still too short
      assert SampleDetector.sample_by_duration?(10.0,
               expected_type: :tv_show,
               expected_duration: 180
             ) == true

      # 20 seconds is acceptable for a 3-minute show (threshold 15s)
      assert SampleDetector.sample_by_duration?(20.0,
               expected_type: :tv_show,
               expected_duration: 180
             ) == false
    end

    test "uses appropriate threshold for webisodes" do
      # 10-minute expected content, 60 seconds is too short (min 90s)
      assert SampleDetector.sample_by_duration?(60.0,
               expected_type: :tv_show,
               expected_duration: 600
             ) == true

      # 120 seconds is acceptable
      assert SampleDetector.sample_by_duration?(120.0,
               expected_type: :tv_show,
               expected_duration: 600
             ) == false
    end
  end

  describe "skip_detection?/1" do
    test "returns true for .flv files" do
      assert SampleDetector.skip_detection?("/movies/sample.flv") == true
    end

    test "returns true for .strm files" do
      assert SampleDetector.skip_detection?("/movies/stream.strm") == true
    end

    test "returns true for .iso files" do
      assert SampleDetector.skip_detection?("/movies/bluray.iso") == true
    end

    test "returns true for .img files" do
      assert SampleDetector.skip_detection?("/movies/dvd.img") == true
    end

    test "returns true for .m2ts files" do
      assert SampleDetector.skip_detection?("/movies/clip.m2ts") == true
    end

    test "returns false for regular video files" do
      assert SampleDetector.skip_detection?("/movies/movie.mkv") == false
      assert SampleDetector.skip_detection?("/movies/movie.mp4") == false
      assert SampleDetector.skip_detection?("/movies/movie.avi") == false
    end

    test "is case-insensitive for extensions" do
      assert SampleDetector.skip_detection?("/movies/sample.FLV") == true
      assert SampleDetector.skip_detection?("/movies/sample.ISO") == true
    end
  end

  describe "apply_detection/2" do
    test "applies detection to ParsedFileInfo struct" do
      info = %ParsedFileInfo{
        type: :movie,
        title: "Avatar",
        original_filename: "avatar.mkv",
        confidence: 0.9,
        quality: Quality.empty()
      }

      result = SampleDetector.apply_detection(info, "/movies/Avatar/Sample/avatar.mkv")

      assert result.is_sample == true
      assert result.is_trailer == false
      assert result.is_extra == false
      assert result.detection_method == :folder
      assert result.detected_folder == "Sample"
    end

    test "skips detection for excluded file types" do
      info = %ParsedFileInfo{
        type: :movie,
        title: "Test",
        original_filename: "test.strm",
        confidence: 0.9,
        quality: Quality.empty()
      }

      result = SampleDetector.apply_detection(info, "/movies/Sample/test.strm")

      # Should not be flagged because .strm files skip detection
      assert result.is_sample == false
      assert result.is_trailer == false
      assert result.is_extra == false
    end

    test "preserves other ParsedFileInfo fields" do
      info = %ParsedFileInfo{
        type: :movie,
        title: "Avatar",
        year: 2009,
        original_filename: "avatar.mkv",
        confidence: 0.95,
        quality: Quality.empty(),
        release_group: "GROUP"
      }

      result = SampleDetector.apply_detection(info, "/movies/Avatar/Sample/avatar.mkv")

      assert result.type == :movie
      assert result.title == "Avatar"
      assert result.year == 2009
      assert result.confidence == 0.95
      assert result.release_group == "GROUP"
    end
  end

  describe "excluded?/1" do
    test "returns true when is_sample is true" do
      assert SampleDetector.excluded?(%{is_sample: true, is_trailer: false, is_extra: false}) ==
               true
    end

    test "returns true when is_trailer is true" do
      assert SampleDetector.excluded?(%{is_sample: false, is_trailer: true, is_extra: false}) ==
               true
    end

    test "returns true when is_extra is true" do
      assert SampleDetector.excluded?(%{is_sample: false, is_trailer: false, is_extra: true}) ==
               true
    end

    test "returns false when nothing is flagged" do
      assert SampleDetector.excluded?(%{is_sample: false, is_trailer: false, is_extra: false}) ==
               false
    end
  end

  describe "exclusion_reason/1" do
    test "returns sample reason for sample files" do
      detection = %{
        is_sample: true,
        is_trailer: false,
        is_extra: false,
        detection_method: :folder,
        detected_folder: "Sample"
      }

      assert SampleDetector.exclusion_reason(detection) == "Sample file (in Sample folder)"
    end

    test "returns trailer reason for trailer files" do
      detection = %{
        is_sample: false,
        is_trailer: true,
        is_extra: false,
        detection_method: :filename,
        detected_folder: nil
      }

      assert SampleDetector.exclusion_reason(detection) == "Trailer (detected from filename)"
    end

    test "returns extra reason for extra files" do
      detection = %{
        is_sample: false,
        is_trailer: false,
        is_extra: true,
        detection_method: :folder,
        detected_folder: "Extras"
      }

      assert SampleDetector.exclusion_reason(detection) == "Extra content (in Extras folder)"
    end

    test "returns nil when nothing is flagged" do
      detection = %{
        is_sample: false,
        is_trailer: false,
        is_extra: false,
        detection_method: nil,
        detected_folder: nil
      }

      assert SampleDetector.exclusion_reason(detection) == nil
    end
  end

  describe "extra_kind/1" do
    test "maps a sample to :sample" do
      detection = SampleDetector.detect("/movies/Avatar/Sample/avatar-sample.mkv")
      assert SampleDetector.extra_kind(detection) == {:sample, :folder}
    end

    test "maps a trailer to :trailer" do
      detection = SampleDetector.detect("/movies/Avatar/avatar-trailer.mkv")
      assert SampleDetector.extra_kind(detection) == {:trailer, :filename}
    end

    test "maps a Plex extras folder to its named kind" do
      detection = SampleDetector.detect("/movies/Avatar/Deleted Scenes/cut.mkv")
      assert SampleDetector.extra_kind(detection) == {:deleted_scene, :folder}
    end

    test "falls back to :other for an unrecognised extras folder" do
      detection = SampleDetector.detect("/movies/Avatar/Other/thing.mkv")
      assert SampleDetector.extra_kind(detection) == {:other, :folder}
    end

    test "maps any filename-detected extra to :other" do
      # The filename layer uses one combined regex that does not report which
      # alternative matched, so there is no honest kind to name here.
      detection = SampleDetector.detect("/movies/Avatar/making of-featurette.mkv")
      assert SampleDetector.extra_kind(detection) == {:other, :filename}
    end

    test "returns nil for a plain movie file" do
      detection = SampleDetector.detect("/movies/Avatar/Avatar.2009.1080p.mkv")
      assert SampleDetector.extra_kind(detection) == nil
    end
  end
end
