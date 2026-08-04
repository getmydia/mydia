defmodule Mydia.Library.SegmentDetection.ChaptersTest do
  # detect/2 stubs the ffprobe binary through application env, which is global,
  # so this file runs serially even though everything else in it is pure.
  use ExUnit.Case, async: false

  alias Mydia.Library.SegmentDetection.Chapters

  @sample_json """
  {"chapters": [
    {"id": 0, "start_time": "0.000000", "end_time": "35.000000",
     "tags": {"title": "Cold Open"}},
    {"id": 1, "start_time": "35.000000", "end_time": "125.500000",
     "tags": {"title": "Opening Credits"}},
    {"id": 2, "start_time": "125.500000", "end_time": "1300.000000",
     "tags": {"title": "Chapter 3"}},
    {"id": 3, "start_time": "1300.000000", "end_time": "1420.000000",
     "tags": {"title": "End Credits"}}
  ]}
  """

  # Runtime of the fixture file, in milliseconds. Every caller in production
  # has one: `analyze_season/2` filters to files with a known duration before
  # any chapter read happens.
  @runtime_ms 1_420_000

  setup do
    on_exit(fn -> Application.delete_env(:mydia, :ffprobe_path) end)

    :ok
  end

  describe "classify/1" do
    test "recognises intro titles" do
      for title <- [
            "Intro",
            "intro",
            "Opening",
            "OP",
            "Opening Credits",
            "Main Titles",
            "Vorspann",
            "Générique de début"
          ] do
        assert Chapters.classify(title) == :intro, "expected #{title} to classify as intro"
      end
    end

    test "recognises credits titles" do
      for title <- [
            "Credits",
            "End Credits",
            "Ending",
            "ED",
            "Closing Credits",
            "Abspann",
            "Générique de fin"
          ] do
        assert Chapters.classify(title) == :credits, "expected #{title} to classify as credits"
      end
    end

    test "recognises numbered opening and ending variants" do
      for {title, type} <- [
            {"OP1", :intro},
            {"OP 2", :intro},
            {"Opening 2", :intro},
            {"ED1", :credits},
            {"ED 2", :credits},
            {"Ending 2", :credits}
          ] do
        assert Chapters.classify(title) == type, "expected #{title} to classify as #{type}"
      end
    end

    test "does not match titles that merely contain a token as a substring" do
      for title <- [
            "Introduction of the Suspect",
            "Introducing Karen",
            "The Credits Union Heist",
            "Chapter 1",
            "Cold Open"
          ] do
        assert Chapters.classify(title) == :unknown, "expected #{title} to classify as unknown"
      end
    end

    test "does not match the near-miss chapter names real libraries actually use" do
      # Measured on a real library: Prologue is the cold open before the theme,
      # Preview is the next-episode teaser after the ending, and Epilogue is a
      # post-credits scene. Each is more common than the true positive it
      # resembles.
      for title <- ["Prologue", "Preview", "Epilogue", "Part A", "Part B", "Episode", "Scene 1"] do
        assert Chapters.classify(title) == :unknown, "expected #{title} to classify as unknown"
      end
    end

    test "does not match ordinary words containing op or ed" do
      for title <- ["Wedding", "Predator", "Stop", "Cooper", "Opera", "Developed"] do
        assert Chapters.classify(title) == :unknown, "expected #{title} to classify as unknown"
      end
    end

    test "handles nil and blank titles" do
      assert Chapters.classify(nil) == :unknown
      assert Chapters.classify("") == :unknown
      assert Chapters.classify("   ") == :unknown
    end
  end

  describe "parse_chapters/2" do
    test "extracts intro and credits segments from ffprobe json" do
      assert {:ok, segments} = Chapters.parse_chapters(@sample_json, @runtime_ms)
      assert segments["intro"] == {35_000, 125_500}
      assert segments["credits"] == {1_300_000, 1_420_000}
    end

    test "resolves each segment type independently" do
      json = """
      {"chapters": [
        {"id": 0, "start_time": "30.000000", "end_time": "120.000000",
         "tags": {"title": "OP"}},
        {"id": 1, "start_time": "120.000000", "end_time": "1400.000000",
         "tags": {"title": "Part A"}}
      ]}
      """

      assert {:ok, segments} = Chapters.parse_chapters(json, @runtime_ms)
      assert segments["intro"] == {30_000, 120_000}
      refute Map.has_key?(segments, "credits")
    end

    test "returns an empty map when no chapter is recognisable" do
      json = """
      {"chapters": [
        {"id": 0, "start_time": "0.000000", "end_time": "600.000000",
         "tags": {"title": "Chapter 1"}}
      ]}
      """

      assert {:ok, segments} = Chapters.parse_chapters(json, @runtime_ms)
      assert segments == %{}
    end

    test "returns an empty map when the file has no chapters" do
      assert {:ok, %{}} = Chapters.parse_chapters(~s({"chapters": []}), @runtime_ms)
    end

    test "tolerates chapters with no tags block" do
      json = ~s({"chapters": [{"id": 0, "start_time": "0.0", "end_time": "10.0"}]})

      assert {:ok, %{}} = Chapters.parse_chapters(json, @runtime_ms)
    end

    test "skips chapters whose span is missing or empty" do
      json = """
      {"chapters": [
        {"id": 0, "tags": {"title": "Opening"}},
        {"id": 1, "start_time": "90.000000", "end_time": "90.000000",
         "tags": {"title": "Ending"}}
      ]}
      """

      assert {:ok, %{}} = Chapters.parse_chapters(json, @runtime_ms)
    end

    test "keeps the first plausible match when a type appears twice" do
      json = """
      {"chapters": [
        {"id": 0, "start_time": "10.000000", "end_time": "40.000000",
         "tags": {"title": "Opening"}},
        {"id": 1, "start_time": "60.000000", "end_time": "90.000000",
         "tags": {"title": "Intro"}}
      ]}
      """

      assert {:ok, segments} = Chapters.parse_chapters(json, @runtime_ms)
      assert segments["intro"] == {10_000, 40_000}
    end

    test "returns an error on malformed json" do
      assert {:error, _reason} = Chapters.parse_chapters("not json at all", @runtime_ms)
    end

    test "skips chapter entries that are not objects" do
      # parse_chapters/2 is public and takes arbitrary JSON, so the array can
      # legally hold non-objects. Access is not implemented for those, and
      # reaching chapter["start_time"] on one would raise.
      json = ~s({"chapters": [null, 42, "Opening", ["OP"], {"not": "a chapter"}]})

      assert {:ok, %{}} = Chapters.parse_chapters(json, @runtime_ms)
    end

    test "mixes non-object entries alongside a usable chapter without losing it" do
      json =
        ~s({"chapters": [null, 42, ) <>
          ~s({"start_time": "60.0", "end_time": "150.0", "tags": {"title": "OP"}}]})

      assert {:ok, %{"intro" => {60_000, 150_000}}} = Chapters.parse_chapters(json, @runtime_ms)
    end

    test "rejects a timestamp with trailing garbage rather than trusting its prefix" do
      # Float.parse/1 would happily return {12.3, "oops"}. Accepting that ships
      # a skip button that jumps to the wrong place.
      json =
        ~s({"chapters": [{"start_time": "60.0oops", "end_time": "150.0", ) <>
          ~s("tags": {"title": "OP"}}]})

      assert {:ok, segments} = Chapters.parse_chapters(json, @runtime_ms)
      refute Map.has_key?(segments, "intro")
    end
  end

  describe "parse_chapters/2 intro plausibility" do
    # A chapter's end_time is where the *next* chapter begins, not where the
    # named thing stops. Every fixture below is the real chapter layout of a
    # file from a production library, reduced to the chapters that matter.

    test "rejects an intro chapter that runs to the credits of a short episode" do
      # Bluey (2018) S01E01, a 7:18 episode carrying exactly two chapters. The
      # opening is a few seconds long, but the chapter titled Intro extends all
      # the way to the credits marker, so its span is 96% of the episode.
      # Trusting it shipped a Skip Intro button that jumped to 7:00 of 7:18.
      json = """
      {"chapters": [
        {"id": 0, "start_time": "0.000000", "end_time": "420.420000",
         "tags": {"title": "Intro"}},
        {"id": 1, "start_time": "420.420000", "end_time": "437.984000",
         "tags": {"title": "Credits"}}
      ]}
      """

      assert {:ok, segments} = Chapters.parse_chapters(json, 437_984)
      refute Map.has_key?(segments, "intro")
    end

    test "keeps the credits of the same file, whose span is genuinely correct" do
      # The credits chapter runs to the next marker or to EOF, and both are
      # where the credits actually end, so the inflation is one-sided.
      json = """
      {"chapters": [
        {"id": 0, "start_time": "0.000000", "end_time": "420.420000",
         "tags": {"title": "Intro"}},
        {"id": 1, "start_time": "420.420000", "end_time": "437.984000",
         "tags": {"title": "Credits"}}
      ]}
      """

      assert {:ok, segments} = Chapters.parse_chapters(json, 437_984)
      assert segments["credits"] == {420_420, 437_984}
    end

    test "falls through an implausible intro to a later chapter that fits" do
      # Jujutsu Kaisen S01E02. Intro here labels the cold open and runs 5:46;
      # the real 90s theme is the next chapter, titled Opening. Keeping the
      # first title match meant the cold open beat the actual opening.
      json = """
      {"chapters": [
        {"id": 0, "start_time": "0.000000", "end_time": "345.990000",
         "tags": {"title": "Intro"}},
        {"id": 1, "start_time": "345.990000", "end_time": "435.960000",
         "tags": {"title": "Opening"}},
        {"id": 2, "start_time": "435.960000", "end_time": "739.970000",
         "tags": {"title": "Part A"}}
      ]}
      """

      assert {:ok, segments} = Chapters.parse_chapters(json, 1_436_020)
      assert segments["intro"] == {345_990, 435_960}
    end

    test "rejects a 19 minute intro with no later candidate to fall back on" do
      # Heavenly Delusion S01E03. Nothing else in the file names an opening, so
      # the intro stays unresolved and the fingerprint path answers instead.
      json = """
      {"chapters": [
        {"id": 0, "start_time": "92.009000", "end_time": "1273.941000",
         "tags": {"title": "Intro"}},
        {"id": 1, "start_time": "1273.941000", "end_time": "1363.947000",
         "tags": {"title": "Credits"}}
      ]}
      """

      assert {:ok, segments} = Chapters.parse_chapters(json, 1_421_994)
      refute Map.has_key?(segments, "intro")
      assert segments["credits"] == {1_273_941, 1_363_947}
    end

    test "keeps a correctly marked opening theme" do
      # One-Punch Man S01: the OP chapter ends where the opening ends, which is
      # what the fast path exists to read. Measured real intros run 40 to 90
      # seconds, so the bound has to leave this untouched.
      json = """
      {"chapters": [
        {"id": 0, "start_time": "64.000000", "end_time": "153.000000",
         "tags": {"title": "OP"}}
      ]}
      """

      assert {:ok, segments} = Chapters.parse_chapters(json, 1_440_000)
      assert segments["intro"] == {64_000, 153_000}
    end

    test "bounds the intro by a fraction of runtime on short-form content" do
      # 180s alone would pass an intro spanning half of a 6 minute episode.
      json = """
      {"chapters": [
        {"id": 0, "start_time": "0.000000", "end_time": "170.000000",
         "tags": {"title": "Opening"}}
      ]}
      """

      assert {:ok, segments} = Chapters.parse_chapters(json, 360_000)
      refute Map.has_key?(segments, "intro")
    end

    test "refuses a negative runtime rather than deriving a bound from it" do
      # The spec says non_neg_integer. A negative runtime is a caller bug, and
      # silently bounding against it would produce a negative ceiling that
      # rejects every intro.
      assert_raise FunctionClauseError, fn ->
        Chapters.parse_chapters(~s({"chapters": []}), -1)
      end
    end

    test "falls back to the absolute bound when runtime is zero" do
      json = """
      {"chapters": [
        {"id": 0, "start_time": "0.000000", "end_time": "90.000000",
         "tags": {"title": "Opening"}}
      ]}
      """

      assert {:ok, segments} = Chapters.parse_chapters(json, 0)
      assert segments["intro"] == {0, 90_000}
    end

    test "bounds the intro absolutely on long-form content" do
      # 25% of a 90 minute runtime is 22 minutes, which is no one's opening.
      json = """
      {"chapters": [
        {"id": 0, "start_time": "0.000000", "end_time": "600.000000",
         "tags": {"title": "Opening"}}
      ]}
      """

      assert {:ok, segments} = Chapters.parse_chapters(json, 5_400_000)
      refute Map.has_key?(segments, "intro")
    end
  end

  describe "detect/2" do
    @tag :tmp_dir
    test "returns the segments parsed out of the probe output", %{tmp_dir: tmp_dir} do
      stub_ffprobe(tmp_dir)

      assert {:ok, segments} = Chapters.detect("/media/show/s01e01.mkv", @runtime_ms)
      assert segments["intro"] == {35_000, 125_500}
      assert segments["credits"] == {1_300_000, 1_420_000}
    end

    @tag :tmp_dir
    test "asks ffprobe for chapters as json", %{tmp_dir: tmp_dir} do
      args_path = stub_ffprobe(tmp_dir)

      assert {:ok, _segments} = Chapters.detect("/media/show/s01e01.mkv", @runtime_ms)

      recorded = File.read!(args_path)
      assert recorded =~ "-show_chapters"
      assert recorded =~ "-print_format json"
      assert recorded =~ "/media/show/s01e01.mkv"
    end

    test "propagates a probe failure" do
      Application.put_env(:mydia, :ffprobe_path, "/nonexistent/ffprobe-binary")

      assert {:error, :ffprobe_not_found} = Chapters.detect("/media/show/s01e01.mkv", @runtime_ms)
    end
  end

  # Installs a fake ffprobe that records its arguments and prints fixture JSON.
  # Returns the path the arguments are recorded to.
  defp stub_ffprobe(tmp_dir) do
    args_path = Path.join(tmp_dir, "args")
    script_path = Path.join(tmp_dir, "ffprobe")

    # args_path is quoted and written with printf: ExUnit derives :tmp_dir from
    # the test name, and this project's test names routinely contain spaces and
    # parentheses, so an unquoted redirection target would split or fail.
    File.write!(script_path, """
    #!/bin/sh
    printf '%s\\n' "$*" > "#{args_path}"
    cat <<'FIXTURE'
    #{@sample_json}
    FIXTURE
    """)

    File.chmod!(script_path, 0o755)
    Application.put_env(:mydia, :ffprobe_path, script_path)

    args_path
  end
end
