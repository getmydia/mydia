defmodule Mydia.Subtitles.FormatTest do
  use ExUnit.Case, async: true

  alias Mydia.Subtitles.Format

  @srt """
  1
  00:00:01,000 --> 00:00:04,000
  Hello there.

  2
  00:00:05,500 --> 00:00:08,250
  General Kenobi.
  """

  describe "convert/3 srt to vtt" do
    test "prepends the WEBVTT header" do
      {:ok, vtt} = Format.convert(@srt, "srt", "vtt")
      assert String.starts_with?(vtt, "WEBVTT\n\n")
    end

    test "rewrites comma decimal separators as periods" do
      {:ok, vtt} = Format.convert(@srt, "srt", "vtt")
      assert vtt =~ "00:00:01.000 --> 00:00:04.000"
      assert vtt =~ "00:00:05.500 --> 00:00:08.250"
      refute vtt =~ ","
    end

    test "keeps the cue text" do
      {:ok, vtt} = Format.convert(@srt, "srt", "vtt")
      assert vtt =~ "General Kenobi."
    end

    test "strips a UTF-8 BOM" do
      {:ok, vtt} = Format.convert("﻿" <> @srt, "srt", "vtt")
      assert String.starts_with?(vtt, "WEBVTT")
    end

    test "normalizes CRLF line endings" do
      crlf = String.replace(@srt, "\n", "\r\n")
      {:ok, vtt} = Format.convert(crlf, "srt", "vtt")
      refute vtt =~ "\r"
    end
  end

  describe "convert/3 vtt to srt" do
    test "round trips back to numbered cues with comma separators" do
      {:ok, vtt} = Format.convert(@srt, "srt", "vtt")
      {:ok, srt} = Format.convert(vtt, "vtt", "srt")

      assert srt =~ "1\n00:00:01,000 --> 00:00:04,000\nHello there."
      assert srt =~ "2\n00:00:05,500 --> 00:00:08,250\nGeneral Kenobi."
      refute srt =~ "WEBVTT"
    end

    test "renumbers cues that carried identifiers" do
      vtt = """
      WEBVTT

      intro
      00:00:01.000 --> 00:00:04.000
      Hello there.
      """

      {:ok, srt} = Format.convert(vtt, "vtt", "srt")
      assert srt =~ "1\n00:00:01,000 --> 00:00:04,000\nHello there."
      refute srt =~ "intro"
    end

    test "drops NOTE and STYLE blocks" do
      vtt = """
      WEBVTT

      NOTE this is a comment

      STYLE
      ::cue { color: red }

      00:00:01.000 --> 00:00:04.000
      Hello there.
      """

      {:ok, srt} = Format.convert(vtt, "vtt", "srt")
      refute srt =~ "NOTE"
      refute srt =~ "STYLE"
      assert srt =~ "Hello there."
    end

    test "defaults a missing hours segment to 00" do
      vtt = """
      WEBVTT

      01:02.500 --> 01:05.000
      Hello there.
      """

      {:ok, srt} = Format.convert(vtt, "vtt", "srt")
      assert srt =~ "00:01:02,500 --> 00:01:05,000"
    end
  end

  describe "convert/3 identity and rejection" do
    test "returns normalized content when the formats match" do
      {:ok, out} = Format.convert(@srt, "srt", "srt")
      assert out =~ "Hello there."
    end

    test "refuses image formats" do
      assert {:error, :image_subtitle} = Format.convert(<<0, 1, 2>>, "pgs", "vtt")
      assert {:error, :image_subtitle} = Format.convert(<<0, 1, 2>>, "vobsub", "vtt")
      assert {:error, :image_subtitle} = Format.convert(<<0, 1, 2>>, "pgs", "pgs")
    end
  end

  describe "the ffmpeg fallback" do
    @ass """
    [Script Info]
    Title: Test
    ScriptType: v4.00+

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,Hello there.
    """

    # Every format outside the SRT and VTT pair falls through to ffmpeg, and no
    # other test in this file reaches that branch. Without this, an invalid
    # option to System.cmd/3 sat undetected behind a fully green suite: the
    # pure-Elixir paths never spawn a process, so nothing raised.
    test "returns a tuple rather than raising for a format needing ffmpeg" do
      result = Format.convert(@ass, "ass", "srt")

      assert is_tuple(result)

      case result do
        {:ok, content} -> assert is_binary(content)
        {:error, :ffmpeg_not_found} -> :ok
        {:error, {:ffmpeg_failed, message}} -> assert is_binary(message)
      end
    end

    test "leaves no temporary files behind" do
      before = tmp_conversion_files()

      Format.convert(@ass, "ass", "srt")

      assert tmp_conversion_files() == before
    end

    defp tmp_conversion_files do
      System.tmp_dir!()
      |> Path.join("mydia-subconv-*")
      |> Path.wildcard()
      |> Enum.sort()
    end
  end

  describe "image_format?/1" do
    test "classifies formats" do
      assert Format.image_format?("pgs")
      assert Format.image_format?("vobsub")
      refute Format.image_format?("srt")
      refute Format.image_format?("vtt")
      refute Format.image_format?("ass")
    end
  end

  describe "detect/1" do
    @fixtures "test/fixtures/subtitles"

    # Real bytes from the live relay. SubDL ships archives whose contents are
    # frequently not what the search result declared, and fixtures in a shape
    # production never produces are how that went unnoticed.
    test "reads ASS out of a file the provider declared as srt" do
      assert Format.detect(File.read!("#{@fixtures}/ass_sample.ass")) == {:ok, "ass"}
    end

    test "reads SRT through a UTF-8 BOM and CRLF line endings" do
      assert Format.detect(File.read!("#{@fixtures}/srt_bom_sample.srt")) == {:ok, "srt"}
    end

    # The cue regex carries no /u modifier, so PCRE matches it byte by byte and
    # Latin-1 content is fine. Asserting it keeps anyone from "fixing" that.
    test "reads SRT out of a non-UTF-8 file" do
      content = File.read!("#{@fixtures}/srt_latin1_sample.srt")

      refute String.valid?(content)
      assert Format.detect(content) == {:ok, "srt"}
    end

    test "reads VTT with and without a BOM" do
      vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nhi\n"

      assert Format.detect(vtt) == {:ok, "vtt"}
      assert Format.detect("﻿" <> vtt) == {:ok, "vtt"}
    end

    test "names MicroDVD as unsupported rather than unrecognized" do
      microdvd = "{100}{200}Hello there\n{300}{400}General Kenobi\n"

      assert Format.detect(microdvd) == {:error, {:unsupported_subtitle_format, "sub"}}
    end

    test "rejects content that is not a subtitle at all" do
      assert Format.detect("<!DOCTYPE html><html><body>404</body></html>") ==
               {:error, :unrecognized_subtitle_content}

      assert Format.detect(<<0, 1, 2, 3, 255, 254>>) == {:error, :unrecognized_subtitle_content}
      assert Format.detect("") == {:error, :unrecognized_subtitle_content}
    end
  end
end
