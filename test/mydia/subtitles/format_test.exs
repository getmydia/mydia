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
end
