defmodule Mydia.Library.ExtraClassifierTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.ExtraClassifier
  alias Mydia.Library.MediaFile
  alias Mydia.Library.Structs.FileMetadata

  # Durations are seconds. Runtimes passed to classify/2 are minutes. Getting
  # that backwards is the single likeliest bug in this module.
  defp file(id, duration_seconds) do
    %MediaFile{id: id, metadata: %FileMetadata{duration: duration_seconds}}
  end

  describe "classify/2 with a known runtime" do
    test "a file at 20% of runtime is an extra" do
      # Ratatouille: 111 minute movie, a 22 minute featurette.
      assert %{"a" => :extra} = ExtraClassifier.classify(111, [file("a", 22 * 60)])
    end

    test "a file at 60% of runtime is a version" do
      assert %{"a" => :version} = ExtraClassifier.classify(111, [file("a", 67 * 60)])
    end

    test "a file at 0.896 of runtime is a version" do
      # LEGO Frozen: Operation Puffins, 16.1 minutes against an 18 minute
      # published runtime. This is the nearest genuine feature to the
      # threshold on galactica and pins the upper margin.
      assert %{"a" => :version} = ExtraClassifier.classify(18, [file("a", 16.1 * 60)])
    end

    test "a file longer than the runtime is a version" do
      # Spider-Man: Into the Spider-Verse Alternate Cut, ratio 1.227.
      assert %{"a" => :version} = ExtraClassifier.classify(117, [file("a", 143.5 * 60)])
    end

    test "compares seconds against minutes correctly" do
      # A 90 minute file against a 100 minute runtime is a version. If the
      # implementation forgets the *60 it compares 5400 against 100 and calls
      # everything a version; if it divides the wrong way it calls everything
      # an extra. This case fails under either mistake only in combination
      # with the next assertion, so both are required.
      assert %{"a" => :version} = ExtraClassifier.classify(100, [file("a", 90 * 60)])
      assert %{"a" => :extra} = ExtraClassifier.classify(100, [file("a", 3 * 60)])
    end

    test "classifies a whole folder at once" do
      files = [file("feature", 111 * 60), file("short", 11 * 60), file("scene", 3 * 60)]

      assert ExtraClassifier.classify(111, files) == %{
               "feature" => :version,
               "short" => :extra,
               "scene" => :extra
             }
    end
  end

  describe "the last-version-survives invariant" do
    test "keeps the longest file when every file would be demoted" do
      # Enchanted on galactica: one file at ratio 0.499, which is actually a
      # different film misfiled into the folder. Without the invariant the
      # movie would report as owning nothing.
      assert %{"a" => :version} = ExtraClassifier.classify(107, [file("a", 53.4 * 60)])
    end

    test "keeps only the longest when several would all be demoted" do
      files = [file("short", 3 * 60), file("longer", 70 * 60)]

      assert ExtraClassifier.classify(200, files) == %{
               "short" => :extra,
               "longer" => :version
             }
    end

    test "does not fire when at least one version survives" do
      files = [file("feature", 100 * 60), file("scene", 3 * 60)]

      assert ExtraClassifier.classify(100, files) == %{
               "feature" => :version,
               "scene" => :extra
             }
    end

    test "does not rescue a lone file that is obviously a clip" do
      # A folder holding only a three minute bonus clip. Rescuing it would make
      # the movie falsely report as owned.
      assert %{"a" => :extra} = ExtraClassifier.classify(111, [file("a", 3 * 60)])
    end

    test "rescues a lone file that is plausibly the feature" do
      # Enchanted on production: one file at ratio 0.499, a different film
      # misfiled into the folder. Above the rescue floor, so it stays the
      # version rather than emptying the movie.
      assert %{"a" => :version} = ExtraClassifier.classify(107, [file("a", 53.4 * 60)])
    end

    test "rescue: false suppresses the invariant" do
      assert %{"a" => :extra} =
               ExtraClassifier.classify(107, [file("a", 53.4 * 60)], rescue: false)
    end
  end

  describe "classify/2 without a runtime" do
    test "falls back to the longest sibling" do
      files = [file("feature", 100 * 60), file("scene", 3 * 60)]

      assert ExtraClassifier.classify(nil, files) == %{
               "feature" => :version,
               "scene" => :extra
             }
    end

    test "falls back to the 600s floor for a lone file" do
      # No runtime and no sibling to compare against. This is the only path
      # that reaches SampleDetector.sample_by_duration?/2, and the only one
      # where the invariant is deliberately not applied: a lone sub-10-minute
      # file with no metadata is confidently an extra, and reporting the movie
      # as not owned is the accurate outcome.
      assert %{"a" => :extra} = ExtraClassifier.classify(nil, [file("a", 3 * 60)])
      assert %{"a" => :version} = ExtraClassifier.classify(nil, [file("a", 95 * 60)])
    end

    test "treats a zero runtime as unknown" do
      assert %{"a" => :extra} = ExtraClassifier.classify(0, [file("a", 3 * 60)])
    end
  end

  describe "files without a duration" do
    test "are absent from the result rather than guessed at" do
      files = [file("feature", 100 * 60), %MediaFile{id: "unanalyzed", metadata: nil}]

      result = ExtraClassifier.classify(100, files)

      assert Map.has_key?(result, "feature")
      refute Map.has_key?(result, "unanalyzed")
    end

    test "an empty list classifies nothing" do
      assert ExtraClassifier.classify(111, []) == %{}
    end
  end
end
