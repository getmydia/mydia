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
