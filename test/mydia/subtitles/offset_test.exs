defmodule Mydia.Subtitles.OffsetTest do
  use ExUnit.Case, async: true

  alias Mydia.Subtitles.Offset

  @srt """
  1
  00:00:10,500 --> 00:00:12,000
  Hello there.

  2
  00:00:20,000 --> 00:00:22,250
  General Kenobi.
  """

  @vtt """
  WEBVTT

  00:00:10.500 --> 00:00:12.000
  Hello there.
  """

  @ass """
  [Script Info]
  Title: Test

  [Events]
  Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
  Dialogue: 0,0:00:10.50,0:00:12.00,Default,,0,0,0,,Hello there.
  """

  describe "shift/3 with a zero offset" do
    test "returns the content byte for byte" do
      assert Offset.shift(@srt, "srt", 0) == @srt
      assert Offset.shift(@vtt, "vtt", 0) == @vtt
      assert Offset.shift(@ass, "ass", 0) == @ass
    end
  end

  describe "shift/3 on SRT" do
    test "moves every cue later by a positive offset" do
      result = Offset.shift(@srt, "srt", 1_500)

      assert result =~ "00:00:12,000 --> 00:00:13,500"
      assert result =~ "00:00:21,500 --> 00:00:23,750"
    end

    test "moves every cue earlier by a negative offset" do
      result = Offset.shift(@srt, "srt", -2_000)

      assert result =~ "00:00:08,500 --> 00:00:10,000"
      assert result =~ "00:00:18,000 --> 00:00:20,250"
    end

    test "clamps a start pushed before zero" do
      result = Offset.shift(@srt, "srt", -11_000)

      assert result =~ "00:00:00,000 --> 00:00:01,000"
    end

    test "drops a cue whose end lands before zero and renumbers what remains" do
      result = Offset.shift(@srt, "srt", -15_000)

      refute result =~ "Hello there."
      assert result =~ "General Kenobi."
      assert result =~ "00:00:05,000 --> 00:00:07,250"
      assert String.starts_with?(String.trim_leading(result), "1\n")
    end

    test "leaves a timestamp inside cue text alone" do
      content = """
      1
      00:00:10,000 --> 00:00:12,000
      Meet me at 00:00:30,000 sharp.
      """

      result = Offset.shift(content, "srt", 1_000)

      assert result =~ "00:00:11,000 --> 00:00:13,000"
      assert result =~ "Meet me at 00:00:30,000 sharp."
    end
  end

  describe "shift/3 on VTT" do
    test "shifts a cue and keeps the header" do
      result = Offset.shift(@vtt, "vtt", 2_000)

      assert String.starts_with?(result, "WEBVTT")
      assert result =~ "00:00:12.500 --> 00:00:14.000"
    end

    test "handles a timestamp with the hours segment omitted" do
      content = "WEBVTT\n\n01:10.000 --> 01:12.000\nLine.\n"

      result = Offset.shift(content, "vtt", 5_000)

      assert result =~ "00:01:15.000 --> 00:01:17.000"
    end

    # Not in the task brief's test list, added because the module drops VTT
    # cues too (mirroring SRT) but nothing above exercised that path.
    test "drops a cue whose end lands before zero, keeping the header and later cues" do
      content = """
      WEBVTT

      00:00:01.000 --> 00:00:02.000
      Cue A.

      00:00:10.000 --> 00:00:11.000
      Cue B.
      """

      result = Offset.shift(content, "vtt", -5_000)

      assert String.starts_with?(result, "WEBVTT")
      refute result =~ "Cue A."
      assert result =~ "Cue B."
      assert result =~ "00:00:05.000 --> 00:00:06.000"
      # No stray blank-line artifact left behind by the dropped cue.
      refute result =~ "\n\n\n"
    end

    # Not in the task brief's test list. VTT timing detection must find the
    # timing line structurally (mirroring SRT), not by testing every line
    # for "-->" independently, or cue text with its own arrow and a
    # timestamp-shaped substring gets treated as a second timing line.
    test "leaves an arrow and a timestamp inside cue text alone" do
      content = """
      WEBVTT

      00:00:10.000 --> 00:00:12.000
      Scene change --> next lap was 01:23.456 flat.
      """

      result = Offset.shift(content, "vtt", 5_000)

      assert result =~ "00:00:15.000 --> 00:00:17.000"
      assert result =~ "Scene change --> next lap was 01:23.456 flat."
    end

    # Not in the task brief's test list. A companion to the above: if cue
    # text with an arrow and a timestamp-shaped substring were mistaken for
    # a second timing line, an offset that pushes that fake timestamp below
    # zero would drop the whole cue even though its real timing is fine.
    test "does not drop a cue when a timestamp-shaped substring in the text would go negative" do
      content = """
      WEBVTT

      00:00:10.000 --> 00:00:12.000
      Turn --> at 00:01.000 mark.
      """

      result = Offset.shift(content, "vtt", -3_000)

      assert result =~ "00:00:07.000 --> 00:00:09.000"
      assert result =~ "Turn --> at 00:01.000 mark."
    end
  end

  describe "shift/3 on ASS" do
    test "shifts a Dialogue line and keeps centiseconds" do
      result = Offset.shift(@ass, "ass", 1_500)

      assert result =~ "Dialogue: 0,0:00:12.00,0:00:13.50,Default"
    end

    test "leaves non-event lines untouched" do
      result = Offset.shift(@ass, "ass", 1_500)

      assert result =~ "[Script Info]"
      assert result =~ "Title: Test"
    end

    # Not in the task brief's test list. The spec calls out both Dialogue:
    # and Comment: lines but the given fixtures only cover Dialogue:.
    test "shifts a Comment line the same way as a Dialogue line" do
      content = """
      [Events]
      Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
      Comment: 0,0:00:10.50,0:00:12.00,Default,,0,0,0,,A note.
      """

      result = Offset.shift(content, "ass", 1_500)

      assert result =~ "Comment: 0,0:00:12.00,0:00:13.50,Default"
    end

    # Not in the task brief's test list. ASS packs the free-text field onto
    # the same physical line as the timestamps, so the rewrite must be
    # scoped to the Start/End fields specifically, not the whole line, or a
    # clock quoted in dialogue gets corrupted the same way an SRT cue's text
    # could.
    test "leaves a timestamp-shaped substring in the dialogue text alone" do
      content = """
      [Events]
      Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
      Dialogue: 0,0:00:10.50,0:00:12.00,Default,,0,0,0,,The clock read 1:23:45.67 exactly.
      """

      result = Offset.shift(content, "ass", 1_500)

      assert result =~ "Dialogue: 0,0:00:12.00,0:00:13.50,Default"
      assert result =~ "The clock read 1:23:45.67 exactly."
    end

    # Not in the task brief's test list. The timestamp-in-text test above
    # has no comma in its text; this one does, to pin that a comma inside
    # the free-text field survives the split/rejoin round trip rather than
    # getting cut at the wrong point.
    test "keeps a comma-containing text field intact, including a timestamp-shaped substring" do
      content = """
      [Events]
      Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
      Dialogue: 0,0:00:10.50,0:00:12.00,Default,,0,0,0,,Wait, the time was 1:23:45.67, right?
      """

      result = Offset.shift(content, "ass", 1_500)

      assert result =~ "Dialogue: 0,0:00:12.00,0:00:13.50,Default"
      assert result =~ "Wait, the time was 1:23:45.67, right?"
    end

    # Not in the task brief's test list. Pins the centisecond truncation
    # behavior for an offset that is not a multiple of 10ms, which every
    # other ASS test sidesteps.
    test "truncates centiseconds consistently when the offset is not a multiple of 10ms" do
      result = Offset.shift(@ass, "ass", 1_234)

      assert result =~ "Dialogue: 0,0:00:11.73,0:00:13.23,Default"
    end
  end

  describe "shift/3 on an unknown format" do
    test "returns the content unchanged" do
      assert Offset.shift(@srt, "sub", 1_000) == @srt
    end
  end
end
