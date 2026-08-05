defmodule Mydia.Downloads.ReleaseIntakeTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.ReleaseIntake
  alias Mydia.Library.Structs.ParsedFileInfo

  describe "parse_release/1 — valid releases" do
    test "valid TV release returns {:ok, tv_show}" do
      assert {:ok, %ParsedFileInfo{type: :tv_show} = info} =
               ReleaseIntake.parse_release("From.S04E07.1080p.WEB.h264-GROUP")

      assert info.season == 4
      assert info.episodes == [7]
    end

    test "valid movie release returns {:ok, movie}" do
      assert {:ok, %ParsedFileInfo{type: :movie} = info} =
               ReleaseIntake.parse_release("The.Matrix.1999.1080p.BluRay.x264-GROUP")

      assert info.year == 1999
    end
  end

  describe "parse_release/1 — validator rejections" do
    test "password-protected name returns the validator's specific reason" do
      assert {:error, :password_protected} =
               ReleaseIntake.parse_release("Password Protected Movie 2020 1080p")
    end

    test "hashed release returns :hashed_release" do
      assert {:error, :hashed_release} =
               ReleaseIntake.parse_release("[A1B2C3D4E5F6A7B8C9D0E1F2] Fake Movie 2020")
    end

    test "numeric-only title returns :numeric_only_title" do
      assert {:error, :numeric_only_title} =
               ReleaseIntake.parse_release("123456789.1080p.BluRay.x264")
    end

    test "suspicious executable extension returns :suspicious_extension" do
      assert {:error, :suspicious_extension} =
               ReleaseIntake.parse_release("From.S04E05.1080p.WEB.h264-ETHEL.exe")
    end

    test "executable extension masked by a trailing tracker tag is still rejected" do
      # The raw final extension is ".org]"; the real ".exe" only surfaces once the
      # tag is stripped. The validator must catch it regardless.
      assert {:error, :suspicious_extension} =
               ReleaseIntake.parse_release("From.S04E05.1080p.WEB.h264-ETHEL.exe[tracker.org]")

      assert {:error, :suspicious_extension} =
               ReleaseIntake.parse_release("From.S04E05.1080p.WEB.h264-ETHEL.exe【高清剧集网】")
    end

    test "rejection reason is distinguishable from a no-match/empty outcome" do
      # A dropped validation gate would surface as a successful parse, not an
      # {:error, atom}. Asserting the atom shape makes the gate observable.
      assert {:error, reason} = ReleaseIntake.parse_release("yenc some binary post")
      assert is_atom(reason)
    end
  end

  describe "parse_release/1 — :unknown type handling" do
    test "unknown type with a usable title still returns {:ok} (suggestion path)" do
      # A short bare title parses as :unknown (no year/quality, title <= 3 chars)
      # but carries a usable title, so the matcher can still produce a suggestion.
      assert {:ok, %ParsedFileInfo{type: :unknown} = info} = ReleaseIntake.parse_release("ab")
      assert is_binary(info.title) and info.title != ""
    end
  end

  # ReleaseParser.infer_media_type/4 returns :movie on a year or quality token
  # without consulting the title, so a titleless :movie is reachable. It cannot
  # be title-matched against a library, so it is rejected at the boundary.
  describe "parse_release/1 — titleless releases" do
    test "a tracker-tagged name whose only title token was the tag is rejected" do
      # The validator runs on the original name, where "[Tracker]" is meaningful
      # content. clean_torrent_name/1 then strips bracket tags before parsing,
      # leaving nothing to use as a title.
      assert {:error, :missing_title} =
               ReleaseIntake.parse_release("[Tracker] (2019) 2160p UHD BluRay x265-GROUP")
    end

    test "a quality-and-group-only name is rejected" do
      assert {:error, :missing_title} =
               ReleaseIntake.parse_release("1080p.BluRay.x264-GROUP")
    end

    test "a normal movie release is still accepted" do
      assert {:ok, %ParsedFileInfo{type: :movie, title: title}} =
               ReleaseIntake.parse_release("The.Matrix.1999.1080p.BluRay.x264-GROUP")

      assert is_binary(title)
    end

    test "a normal TV release is still accepted" do
      assert {:ok, %ParsedFileInfo{type: :tv_show, title: title}} =
               ReleaseIntake.parse_release("From.S04E07.1080p.WEB.h264-GROUP")

      assert is_binary(title)
    end
  end
end
