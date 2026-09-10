defmodule Mydia.Downloads.ReleaseValidatorTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.ReleaseValidator

  describe "validate_release/1 - hashed releases" do
    test "rejects release with 32-char hex hash in brackets" do
      # Use valid hex characters (0-9, A-F only)
      name = "[A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6] The Matrix 1999 1080p"

      assert {:error, :hashed_release} = ReleaseValidator.validate_release(name)
    end

    test "rejects release with 24-char hex hash in brackets" do
      # Use valid hex characters (0-9, A-F only)
      name = "[A1B2C3D4E5F6A7B8C9D0E1F2] Movie Title 2020"

      assert {:error, :hashed_release} = ReleaseValidator.validate_release(name)
    end

    test "rejects release with hex hash in parentheses" do
      # Use valid hex characters (0-9, A-F only)
      name = "(A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6) Movie 2020 720p"

      assert {:error, :hashed_release} = ReleaseValidator.validate_release(name)
    end

    test "accepts release with short tracker ID in brackets" do
      # Short tracker IDs (< 24 chars) should not trigger rejection
      name = "[TRACKER123] The Matrix 1999 1080p"

      assert {:ok, ^name} = ReleaseValidator.validate_release(name)
    end

    test "accepts release with normal brackets containing text" do
      name = "[BluRay] The Matrix 1999 1080p x264"

      assert {:ok, ^name} = ReleaseValidator.validate_release(name)
    end
  end

  describe "validate_release/1 - numeric-only titles" do
    test "rejects release with only numbers in title" do
      name = "123456.1080p.BluRay.x264"

      assert {:error, :numeric_only_title} = ReleaseValidator.validate_release(name)
    end

    test "rejects release with numbers and dots only" do
      name = "12.34.56.2020.720p.WEB-DL"

      assert {:error, :numeric_only_title} = ReleaseValidator.validate_release(name)
    end

    test "accepts release with alphanumeric title" do
      name = "Matrix 1999 1080p BluRay"

      assert {:ok, ^name} = ReleaseValidator.validate_release(name)
    end

    test "accepts release with title containing numbers" do
      # "24" alone might be flagged as numeric-only, so use a show with letters
      name = "24.Hours.S01E01.1080p.WEB-DL"

      assert {:ok, ^name} = ReleaseValidator.validate_release(name)
    end

    test "accepts release starting with numbers but having text" do
      name = "21.Jump.Street.2012.1080p.BluRay.x264"

      assert {:ok, ^name} = ReleaseValidator.validate_release(name)
    end
  end

  describe "validate_release/1 - password-protected releases" do
    test "rejects release with 'password' in name" do
      name = "Password Protected Movie 2020 1080p"

      assert {:error, :password_protected} = ReleaseValidator.validate_release(name)
    end

    test "rejects release with 'passworded' in name" do
      name = "Movie.Title.2020.Passworded.1080p"

      assert {:error, :password_protected} = ReleaseValidator.validate_release(name)
    end

    test "rejects release with 'pass protected' in name" do
      name = "Movie Pass Protected 2020 BluRay"

      assert {:error, :password_protected} = ReleaseValidator.validate_release(name)
    end

    test "rejects release with PASSWORD in brackets" do
      name = "Movie [PASSWORD] 2020 1080p"

      assert {:error, :password_protected} = ReleaseValidator.validate_release(name)
    end

    test "accepts normal release without password references" do
      name = "The.Matrix.1999.1080p.BluRay.x264"

      assert {:ok, ^name} = ReleaseValidator.validate_release(name)
    end
  end

  describe "validate_release/1 - reversed patterns" do
    test "rejects release with p0801 pattern" do
      name = "p0801.Movie.Title.1080p.BluRay"

      assert {:error, :reversed_pattern} = ReleaseValidator.validate_release(name)
    end

    test "rejects release with p027 pattern" do
      name = "p027.Some.Movie.2020.720p"

      assert {:error, :reversed_pattern} = ReleaseValidator.validate_release(name)
    end

    test "rejects release with P1234 pattern (uppercase)" do
      name = "P1234.Movie.Title.WEB-DL"

      assert {:error, :reversed_pattern} = ReleaseValidator.validate_release(name)
    end

    test "accepts normal release starting with letter p" do
      # Normal title starting with P should work
      name = "Prometheus.2012.1080p.BluRay.x264"

      assert {:ok, ^name} = ReleaseValidator.validate_release(name)
    end

    test "accepts release with p in the middle" do
      name = "The.Shape.of.Water.2017.1080p.BluRay"

      assert {:ok, ^name} = ReleaseValidator.validate_release(name)
    end
  end

  describe "validate_release/1 - yenc patterns" do
    test "rejects release with yenc in name" do
      name = "yenc Movie Title 2020 1080p"

      assert {:error, :yenc_pattern} = ReleaseValidator.validate_release(name)
    end

    test "rejects release with [yenc] prefix" do
      name = "[yenc] Some Movie 2020 BluRay"

      assert {:error, :yenc_pattern} = ReleaseValidator.validate_release(name)
    end

    test "rejects release with YENC (uppercase)" do
      name = "YENC.Movie.Title.2020.720p"

      assert {:error, :yenc_pattern} = ReleaseValidator.validate_release(name)
    end

    test "accepts normal release without yenc" do
      name = "The.Matrix.1999.1080p.BluRay.x264"

      assert {:ok, ^name} = ReleaseValidator.validate_release(name)
    end
  end

  describe "validate_release/1 - suspicious executable extensions" do
    test "rejects .exe release disguised as 1080p TV episode" do
      name = "From.S04E05.1080p.WEB.h264-ETHEL.exe"

      assert {:error, :suspicious_extension} = ReleaseValidator.validate_release(name)
    end

    test "rejects .exe release disguised as movie" do
      name = "The.Matrix.1999.1080p.BluRay.x264.exe"

      assert {:error, :suspicious_extension} = ReleaseValidator.validate_release(name)
    end

    test "rejects uppercase .EXE extension" do
      name = "Your.Friends.and.Neighbors.S02E07.1080p.WEB.h264-ETHEL.EXE"

      assert {:error, :suspicious_extension} = ReleaseValidator.validate_release(name)
    end

    test "rejects executable extension with trailing whitespace" do
      name = "Movie.2024.1080p.BluRay.x264.exe "

      assert {:error, :suspicious_extension} = ReleaseValidator.validate_release(name)
    end

    test "rejects other Windows executable extensions" do
      for ext <- ~w(.scr .bat .cmd .com .msi .vbs .js .jar .pif) do
        name = "Movie.Title.2020.1080p.BluRay.x264#{ext}"
        assert {:error, :suspicious_extension} = ReleaseValidator.validate_release(name)
      end
    end

    # Malware that the .exe filter already stops comes back wrapped in an
    # archive: this name held a single .exe inside a .zipx. Mydia imports
    # video files only, so an archive release cannot import either way.
    test "rejects archive-wrapped release disguised as TV episode" do
      name = "Stillwater Bay S03E04 1080p ATVP WEB-DL DDP5 1 Atmos.zipx"

      assert {:error, :suspicious_extension} = ReleaseValidator.validate_release(name)
    end

    test "rejects other archive extensions" do
      for ext <- ~w(.zip .zipx .rar .7z .ZIPX) do
        name = "Movie.Title.2020.1080p.BluRay.x264#{ext}"
        assert {:error, :suspicious_extension} = ReleaseValidator.validate_release(name)
      end
    end

    test "rejects archive extension hidden behind a trailing site tag" do
      name = "Stillwater Bay S03E04 1080p WEB H264-NTb.zipx[EZTVx.to]"

      assert {:error, :suspicious_extension} = ReleaseValidator.validate_release(name)
    end

    test "accepts release without an extension" do
      name = "From.S04E05.1080p.WEB.h264-ETHEL"

      assert {:ok, ^name} = ReleaseValidator.validate_release(name)
    end

    test "accepts release with legitimate .mkv extension" do
      name = "From.S04E05.1080p.WEB.h264-ETHEL.mkv"

      assert {:ok, ^name} = ReleaseValidator.validate_release(name)
    end
  end

  describe "validate_release/1 - no meaningful content" do
    test "rejects release with only brackets and quality markers" do
      name = "[Tracker] (2020) 1080p BluRay x264"

      assert {:error, :no_meaningful_content} = ReleaseValidator.validate_release(name)
    end

    test "rejects release with only special characters after cleanup" do
      name = "..--__ (2020) 1080p"

      assert {:error, :no_meaningful_content} = ReleaseValidator.validate_release(name)
    end

    test "accepts release with actual title content" do
      name = "The.Matrix.1999.1080p.BluRay.x264"

      assert {:ok, ^name} = ReleaseValidator.validate_release(name)
    end

    test "accepts release with minimal but valid title" do
      name = "Pi 1998 1080p BluRay"

      assert {:ok, ^name} = ReleaseValidator.validate_release(name)
    end
  end

  describe "validate_release/1 - valid releases" do
    test "accepts standard movie release" do
      name = "The.Matrix.1999.1080p.BluRay.x264-SPARKS"

      assert {:ok, ^name} = ReleaseValidator.validate_release(name)
    end

    test "accepts TV episode release" do
      name = "Breaking.Bad.S01E01.720p.HDTV.x264-CTU"

      assert {:ok, ^name} = ReleaseValidator.validate_release(name)
    end

    test "accepts season pack release" do
      name = "Game.of.Thrones.S08.COMPLETE.1080p.BluRay.x265"

      assert {:ok, ^name} = ReleaseValidator.validate_release(name)
    end

    test "accepts release with tracker prefix" do
      name = "[bitsearch.to] The Matrix 1999 1080p BluRay"

      assert {:ok, ^name} = ReleaseValidator.validate_release(name)
    end

    test "accepts release with Chinese characters" do
      name = "【高清剧集网】The Matrix 1999 1080p"

      assert {:ok, ^name} = ReleaseValidator.validate_release(name)
    end

    test "accepts release with parentheses in title" do
      name = "The Matrix (Remastered) 1999 1080p BluRay"

      assert {:ok, ^name} = ReleaseValidator.validate_release(name)
    end

    test "accepts release with special edition markers" do
      name = "The.Matrix.1999.Directors.Cut.1080p.BluRay"

      assert {:ok, ^name} = ReleaseValidator.validate_release(name)
    end

    test "accepts release with multiple quality indicators" do
      name = "Inception.2010.1080p.BluRay.DTS.x264.HDR"

      assert {:ok, ^name} = ReleaseValidator.validate_release(name)
    end

    test "accepts anime release" do
      name = "[SubsPlease] One Piece - 1000 (1080p) [12345678].mkv"

      assert {:ok, ^name} = ReleaseValidator.validate_release(name)
    end

    test "accepts release with proper group name" do
      name = "The.Matrix.1999.REMASTERED.1080p.BluRay.x265-RARBG"

      assert {:ok, ^name} = ReleaseValidator.validate_release(name)
    end
  end

  describe "validate_release/1 - edge cases" do
    test "accepts empty string gracefully" do
      # Empty string should not crash, but likely won't parse well
      name = ""

      # Since empty string has no content, it should be rejected
      assert {:error, :no_meaningful_content} = ReleaseValidator.validate_release(name)
    end

    test "accepts very long release name" do
      name =
        "The.Very.Long.Title.Of.A.Movie.With.Extremely.Detailed.Information.2020.REMASTERED.EXTENDED.DIRECTORS.CUT.IMAX.1080p.BluRay.DTS.HD.MA.7.1.x265.HEVC.10bit.HDR.DV-GROUP"

      assert {:ok, ^name} = ReleaseValidator.validate_release(name)
    end

    test "handles mixed case correctly" do
      name = "ThE.MaTrIx.1999.1080P.bLuRaY.X264"

      assert {:ok, ^name} = ReleaseValidator.validate_release(name)
    end

    test "handles unicode characters" do
      name = "Amélie.2001.1080p.BluRay.x264"

      assert {:ok, ^name} = ReleaseValidator.validate_release(name)
    end
  end
end
