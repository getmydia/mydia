defmodule Mydia.Library.SegmentDetection.ChaptersTest do
  # detect/1 stubs the ffprobe binary through application env, which is global,
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

  describe "parse_chapters/1" do
    test "extracts intro and credits segments from ffprobe json" do
      assert {:ok, segments} = Chapters.parse_chapters(@sample_json)
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

      assert {:ok, segments} = Chapters.parse_chapters(json)
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

      assert {:ok, segments} = Chapters.parse_chapters(json)
      assert segments == %{}
    end

    test "returns an empty map when the file has no chapters" do
      assert {:ok, %{}} = Chapters.parse_chapters(~s({"chapters": []}))
    end

    test "tolerates chapters with no tags block" do
      json = ~s({"chapters": [{"id": 0, "start_time": "0.0", "end_time": "10.0"}]})

      assert {:ok, %{}} = Chapters.parse_chapters(json)
    end

    test "skips chapters whose span is missing or empty" do
      json = """
      {"chapters": [
        {"id": 0, "tags": {"title": "Opening"}},
        {"id": 1, "start_time": "90.000000", "end_time": "90.000000",
         "tags": {"title": "Ending"}}
      ]}
      """

      assert {:ok, %{}} = Chapters.parse_chapters(json)
    end

    test "keeps the first match when a type appears twice" do
      json = """
      {"chapters": [
        {"id": 0, "start_time": "10.000000", "end_time": "40.000000",
         "tags": {"title": "Opening"}},
        {"id": 1, "start_time": "60.000000", "end_time": "90.000000",
         "tags": {"title": "Intro"}}
      ]}
      """

      assert {:ok, segments} = Chapters.parse_chapters(json)
      assert segments["intro"] == {10_000, 40_000}
    end

    test "returns an error on malformed json" do
      assert {:error, _reason} = Chapters.parse_chapters("not json at all")
    end
  end

  describe "detect/1" do
    @tag :tmp_dir
    test "returns the segments parsed out of the probe output", %{tmp_dir: tmp_dir} do
      stub_ffprobe(tmp_dir)

      assert {:ok, segments} = Chapters.detect("/media/show/s01e01.mkv")
      assert segments["intro"] == {35_000, 125_500}
      assert segments["credits"] == {1_300_000, 1_420_000}
    end

    @tag :tmp_dir
    test "asks ffprobe for chapters as json", %{tmp_dir: tmp_dir} do
      args_path = stub_ffprobe(tmp_dir)

      assert {:ok, _segments} = Chapters.detect("/media/show/s01e01.mkv")

      recorded = File.read!(args_path)
      assert recorded =~ "-show_chapters"
      assert recorded =~ "-print_format json"
      assert recorded =~ "/media/show/s01e01.mkv"
    end

    test "propagates a probe failure" do
      Application.put_env(:mydia, :ffprobe_path, "/nonexistent/ffprobe-binary")

      assert {:error, :ffprobe_not_found} = Chapters.detect("/media/show/s01e01.mkv")
    end
  end

  # Installs a fake ffprobe that records its arguments and prints fixture JSON.
  # Returns the path the arguments are recorded to.
  defp stub_ffprobe(tmp_dir) do
    args_path = Path.join(tmp_dir, "args")
    script_path = Path.join(tmp_dir, "ffprobe")

    File.write!(script_path, """
    #!/bin/sh
    echo "$@" > #{args_path}
    cat <<'FIXTURE'
    #{@sample_json}
    FIXTURE
    """)

    File.chmod!(script_path, 0o755)
    Application.put_env(:mydia, :ffprobe_path, script_path)

    args_path
  end
end
