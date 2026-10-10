defmodule HarvestSonarrFixturesTest do
  # The harvester script defines its module at load time but its top-level
  # `.run/1` call is gated on the `MYDIA_HARVEST_AUTORUN=false` env var.
  # Setting that before require_file/1 lets us call the parser internals
  # without triggering live GitHub fetches during the test suite.

  use ExUnit.Case, async: false

  setup_all do
    previous = System.get_env("MYDIA_HARVEST_AUTORUN")
    System.put_env("MYDIA_HARVEST_AUTORUN", "false")
    Code.require_file(Path.expand("../../scripts/harvest_sonarr_fixtures.exs", __DIR__))

    on_exit(fn ->
      if previous do
        System.put_env("MYDIA_HARVEST_AUTORUN", previous)
      else
        System.delete_env("MYDIA_HARVEST_AUTORUN")
      end
    end)

    # Returned through the test context so the calls resolve at runtime: the
    # module only exists after require_file, which is after this file compiled.
    %{harvester: HarvestSonarrFixtures}
  end

  test "extracts (input, expected) tuples from a single-line TestCase method", %{
    harvester: harvester
  } do
    cs = """
        [TestCase("Series.With.Title.S02E15", "Series With Title", 2, 15)]
        [TestCase("Show.S01E01.HDTV.x264", "Show", 1, 1)]
        public void should_parse_single_episode(string postTitle, string title, int seasonNumber, int episodeNumber)
        {
        }
    """

    {entries, exclusions} = harvester.parse_file("Synthetic.cs", cs)

    assert exclusions == []
    assert length(entries) == 2

    assert Enum.any?(entries, fn e ->
             e.input == "Series.With.Title.S02E15" and
               e.expected == %{title: "Series With Title", season: 2, episode: 15}
           end)

    assert Enum.any?(entries, fn e ->
             e.input == "Show.S01E01.HDTV.x264" and
               e.expected == %{title: "Show", season: 1, episode: 1}
           end)
  end

  test "extracts new[] { ... } integer arrays into Elixir lists", %{harvester: harvester} do
    cs = """
        [TestCase("Series.S03E01-06.HDTV.x264", "Series", 3, new[] { 1, 2, 3, 4, 5, 6 })]
        public void should_parse_multi_episode(string postTitle, string title, int seasonNumber, int[] episodeNumbers)
        {
        }
    """

    {entries, exclusions} = harvester.parse_file("Synthetic.cs", cs)

    assert exclusions == []
    assert length(entries) == 1
    [entry] = entries
    assert entry.input == "Series.S03E01-06.HDTV.x264"
    assert entry.expected == %{title: "Series", season: 3, episodes: [1, 2, 3, 4, 5, 6]}
  end

  test "strips NUnit `Description = \"...\"` metadata argument", %{harvester: harvester} do
    cs = """
        [TestCase("Movie.1990.German.x264", "Movie", 1990, Description = "year at end")]
        public void should_parse_movie_year(string postTitle, string title, int year)
        {
        }
    """

    {entries, _} = harvester.parse_file("Synthetic.cs", cs)
    assert length(entries) == 1
    [entry] = entries
    assert entry.expected == %{title: "Movie", year: 1990}
  end

  test "supports verbatim strings (@\"...\") with quoted segments", %{harvester: harvester} do
    cs = ~S"""
        [TestCase(@"Series Title - S02E21 - ""Episode With Quotes"" - 720p", "Series Title", 2, 21)]
        public void should_parse_verbatim(string postTitle, string title, int seasonNumber, int episodeNumber)
        {
        }
    """

    {entries, _} = harvester.parse_file("Synthetic.cs", cs)
    assert length(entries) == 1
    [entry] = entries
    assert entry.input == ~s|Series Title - S02E21 - "Episode With Quotes" - 720p|
    assert entry.expected == %{title: "Series Title", season: 2, episode: 21}
  end

  test "supports decimal episode numbers", %{harvester: harvester} do
    cs = """
        [TestCase("[Subs] Show - 12.5 (1080p).mkv", "Show", 12.5)]
        public void should_parse_decimal_absolute(string postTitle, string title, double absoluteEpisodeNumber)
        {
        }
    """

    {entries, _} = harvester.parse_file("Synthetic.cs", cs)
    assert length(entries) == 1
    [entry] = entries
    assert entry.expected == %{title: "Show", absolute_episode: 12.5}
  end

  test "supports empty `new string[0]` arrays", %{harvester: harvester} do
    cs = """
        [TestCase("Name.S01E20.eng.srt", new string[0], "Subtitles", "English")]
        public void should_parse_subtitle(string filename, string[] languageTags, string expected, string expectedLanguage)
        {
        }
    """

    {entries, exclusions} = harvester.parse_file("Synthetic.cs", cs)
    assert exclusions == []
    assert length(entries) == 1
    [entry] = entries
    assert entry.expected.language_tags == []
    assert entry.expected.expected == "Subtitles"
    assert entry.expected.language == "English"
  end

  test "excludes non-empty sized arrays instead of treating them as empty", %{
    harvester: harvester
  } do
    cs = """
        [TestCase("Name.S01E20.eng.srt", new string[5], "Subtitles", "English")]
        public void should_parse_subtitle(string filename, string[] languageTags, string expected, string expectedLanguage)
        {
        }
    """

    {entries, exclusions} = harvester.parse_file("Synthetic.cs", cs)

    assert entries == []

    assert [
             {"Synthetic.cs", :unparseable_test_case,
              "[TestCase(\"Name.S01E20.eng.srt\", new string[5], \"Subtitles\", \"English\")]"}
           ] = exclusions
  end

  test "logs methods with unknown parameter names in exclusion list (does not crash)", %{
    harvester: harvester
  } do
    cs = """
        [TestCase("Some.Input", true)]
        public void should_check_something(string input, bool unknownFieldNobodyMapped)
        {
        }
    """

    {entries, exclusions} = harvester.parse_file("Synthetic.cs", cs)
    assert entries == []
    assert length(exclusions) == 1
    [{file, method, reason}] = exclusions
    assert file == "Synthetic.cs"
    assert method == "should_check_something"
    assert match?({:unknown_params, _}, reason)
  end

  test "comments (// ...) do not break parsing", %{harvester: harvester} do
    cs = """
        // This is a comment
        [TestCase("Show.S01E01", "Show", 1, 1)]
        // Another comment
        public void should_parse(string postTitle, string title, int seasonNumber, int episodeNumber)
        {
        }
    """

    {entries, _} = harvester.parse_file("Synthetic.cs", cs)
    assert length(entries) == 1
  end

  test "test cases without a following method are discarded (no orphan entries)", %{
    harvester: harvester
  } do
    cs = """
        [TestCase("Orphan.Input", "Orphan", 1, 1)]
        [TestCase("Another.Orphan", "Another", 2, 2)]
    """

    {entries, exclusions} = harvester.parse_file("Synthetic.cs", cs)
    assert entries == []
    assert exclusions == []
  end
end
