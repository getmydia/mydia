defmodule Mydia.Downloads.SeedingGoalTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.SeedingGoal
  alias Mydia.Indexers.Structs.TrackerTerms

  @day 86_400

  describe "met?/3" do
    test "nil terms are met: behavior unchanged" do
      assert SeedingGoal.met?(nil, 0.0, 0)
    end

    test "terms without a ratio, a seed time or privacy are met" do
      assert SeedingGoal.met?(%TrackerTerms{download_volume_factor: 0.0}, 0.0, 0)
      assert SeedingGoal.met?(%TrackerTerms{private?: false}, 0.0, 0)
    end

    test "ratio only: the ratio decides" do
      terms = %TrackerTerms{private?: true, minimum_ratio: 1.0}

      refute SeedingGoal.met?(terms, 0.99, 30 * @day)
      assert SeedingGoal.met?(terms, 1.0, 0)
      refute SeedingGoal.met?(terms, nil, 30 * @day)
    end

    test "seed time only: the seed time decides" do
      terms = %TrackerTerms{private?: true, minimum_seed_time: 3 * @day}

      refute SeedingGoal.met?(terms, 50.0, 3 * @day - 1)
      assert SeedingGoal.met?(terms, 0.0, 3 * @day)
      refute SeedingGoal.met?(terms, 50.0, nil)
    end

    test "both: whichever comes first" do
      terms = %TrackerTerms{private?: true, minimum_ratio: 1.0, minimum_seed_time: 3 * @day}

      refute SeedingGoal.met?(terms, 0.5, @day)
      assert SeedingGoal.met?(terms, 1.2, @day)
      assert SeedingGoal.met?(terms, 0.5, 4 * @day)
    end

    test "a public tracker with an operator ratio is still held to it" do
      refute SeedingGoal.met?(%TrackerTerms{private?: false, minimum_ratio: 1.0}, 0.5, 0)
    end

    test "private without a known ratio or seed time is never met" do
      refute SeedingGoal.met?(%TrackerTerms{private?: true}, 100.0, 365 * @day)
    end
  end

  describe "applies?/1" do
    test "only terms that ask for something apply" do
      refute SeedingGoal.applies?(nil)
      refute SeedingGoal.applies?(%TrackerTerms{upload_volume_factor: 2.0})
      assert SeedingGoal.applies?(%TrackerTerms{private?: true})
      assert SeedingGoal.applies?(%TrackerTerms{minimum_ratio: 1.0})
      assert SeedingGoal.applies?(%TrackerTerms{minimum_seed_time: 60})
    end
  end

  describe "terms/1" do
    test "reads the frozen terms with string or atom keys" do
      frozen = %{"private" => true, "minimum_ratio" => 1.0, "minimum_seed_time" => 60}

      assert %TrackerTerms{private?: true, minimum_ratio: 1.0, minimum_seed_time: 60} =
               SeedingGoal.terms(%{metadata: %{"tracker_terms" => frozen}})

      assert %TrackerTerms{minimum_ratio: 2.0} =
               SeedingGoal.terms(%{metadata: %{tracker_terms: %{minimum_ratio: 2.0}}})
    end

    test "is nil without metadata or terms" do
      assert SeedingGoal.terms(%{metadata: nil}) == nil
      assert SeedingGoal.terms(%{metadata: %{"quality" => %{}}}) == nil
    end
  end

  describe "seeding_time/5" do
    @now ~U[2031-05-10 12:00:00Z]

    test "prefers what the client reports, seeding or not" do
      assert SeedingGoal.seeding_time(500, true, ~U[2031-05-10 11:00:00Z], nil, @now) == 500
      assert SeedingGoal.seeding_time(500, false, ~U[2031-05-10 11:00:00Z], nil, @now) == 500
    end

    test "while seeding, falls back to the client's completion time, then the download's" do
      assert SeedingGoal.seeding_time(nil, true, ~U[2031-05-10 11:00:00Z], nil, @now) == 3600

      assert SeedingGoal.seeding_time(nil, true, nil, ~U[2031-05-10 11:30:00Z], @now) == 1800
    end

    test "without a reported time, a torrent that is not seeding has no known seed time" do
      # Paused, stopped, gone or unreachable: wall-clock time since completion
      # would count time it did not seed.
      assert SeedingGoal.seeding_time(nil, false, ~U[2031-05-01 00:00:00Z], nil, @now) == nil
      assert SeedingGoal.seeding_time(nil, false, nil, ~U[2031-05-01 00:00:00Z], @now) == nil
    end

    test "is nil when nothing is known, and never negative" do
      assert SeedingGoal.seeding_time(nil, true, nil, nil, @now) == nil
      assert SeedingGoal.seeding_time(nil, true, ~U[2031-05-11 00:00:00Z], nil, @now) == 0
    end
  end

  describe "for_download/2" do
    @now ~U[2031-05-10 12:00:00Z]

    test "is nil when no goal applies" do
      assert SeedingGoal.for_download(%{metadata: %{}, ratio: 0.0}, @now) == nil
    end

    test "a row that is not seeding gets no seed time from its completion time" do
      row = %{
        indexer: "Velvet Lantern",
        metadata: %{"tracker_terms" => %{"minimum_seed_time" => 3600}},
        status: "missing",
        ratio: 0.0,
        seeding_time: nil,
        completed_at: ~U[2031-05-01 00:00:00Z],
        db_completed_at: ~U[2031-05-01 00:00:00Z]
      }

      assert %SeedingGoal{seeding_time: nil, met?: false} = SeedingGoal.for_download(row, @now)

      assert %SeedingGoal{seeding_time: 820_800, met?: true} =
               SeedingGoal.for_download(%{row | status: "seeding"}, @now)
    end

    test "summarizes progress toward the goal" do
      row = %{
        indexer: "Velvet Lantern",
        metadata: %{"tracker_terms" => %{"private" => true, "minimum_ratio" => 1.0}},
        ratio: 0.42,
        seeding_time: 3600,
        completed_at: nil,
        db_completed_at: nil
      }

      assert %SeedingGoal{
               tracker: "Velvet Lantern",
               required_ratio: 1.0,
               required_seed_time: nil,
               ratio: 0.42,
               seeding_time: 3600,
               met?: false
             } = SeedingGoal.for_download(row, @now)
    end
  end
end
