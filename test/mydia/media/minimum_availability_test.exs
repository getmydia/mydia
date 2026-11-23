defmodule Mydia.Media.MinimumAvailabilityTest do
  use ExUnit.Case, async: true

  alias Mydia.Media.MediaItem
  alias Mydia.Media.MinimumAvailability
  alias Mydia.Metadata.Structs.MediaMetadata

  defp movie(dates, override \\ nil) do
    metadata =
      struct!(
        %MediaMetadata{provider_id: "9101", provider: :tmdb, media_type: :movie},
        dates
      )

    %MediaItem{
      type: "movie",
      title: "Copper Weather",
      metadata: metadata,
      minimum_availability: override
    }
  end

  describe "eligible_on/2" do
    test "announced never waits" do
      item = movie(%{release_date: ~D[2031-03-01], digital_release_date: ~D[2031-05-12]})
      assert MinimumAvailability.eligible_on(item, "announced") == nil
    end

    test "in_cinemas waits for the theatrical date" do
      assert MinimumAvailability.eligible_on(movie(%{release_date: ~D[2031-03-01]}), "in_cinemas") ==
               ~D[2031-03-01]

      assert MinimumAvailability.eligible_on(movie(%{}), "in_cinemas") == nil
    end

    test "released takes the earlier of digital and physical" do
      digital_first =
        movie(%{digital_release_date: ~D[2031-05-12], physical_release_date: ~D[2031-07-01]})

      physical_first =
        movie(%{digital_release_date: ~D[2031-08-01], physical_release_date: ~D[2031-07-01]})

      assert MinimumAvailability.eligible_on(digital_first, "released") == ~D[2031-05-12]
      assert MinimumAvailability.eligible_on(physical_first, "released") == ~D[2031-07-01]
    end

    test "released falls back to theatrical plus 90 days" do
      assert MinimumAvailability.eligible_on(movie(%{release_date: ~D[2031-03-01]}), "released") ==
               ~D[2031-05-30]
    end

    test "released never waits past theatrical plus 90 days for a late reissue" do
      item = movie(%{release_date: ~D[1984-06-01], physical_release_date: ~D[2027-03-01]})

      assert MinimumAvailability.eligible_on(item, "released") == ~D[1984-08-30]
    end

    test "released with no dates at all does not wait" do
      assert MinimumAvailability.eligible_on(movie(%{}), "released") == nil
    end

    test "a movie without metadata never waits" do
      item = %MediaItem{type: "movie", title: "Copper Weather", metadata: nil}

      for level <- ["announced", "in_cinemas", "released"] do
        assert MinimumAvailability.eligible_on(item, level) == nil
      end
    end
  end

  describe "effective/2" do
    test "the movie's override beats the global level" do
      assert MinimumAvailability.effective(movie(%{}, "in_cinemas"), "released") == "in_cinemas"
    end

    test "no override follows the global level" do
      assert MinimumAvailability.effective(movie(%{}), "released") == "released"
    end
  end

  describe "status/3" do
    test "unavailable the day before the eligible date, available on it" do
      item = movie(%{release_date: ~D[2031-03-01]}, "in_cinemas")

      assert %{level: "in_cinemas", eligible_on: ~D[2031-03-01], available?: false} =
               MinimumAvailability.status(item, "released", ~D[2031-02-28])

      assert %{available?: true} = MinimumAvailability.status(item, "released", ~D[2031-03-01])
    end

    test "an unreleased movie TMDB has no date for waits until one is known" do
      item = movie(%{status: "Post Production"})

      assert %{eligible_on: nil, available?: false} =
               MinimumAvailability.status(item, "released", ~D[2031-01-01])

      assert %{eligible_on: nil, available?: false} =
               MinimumAvailability.status(item, "in_cinemas", ~D[2031-01-01])

      assert %{available?: true} = MinimumAvailability.status(item, "announced", ~D[2031-01-01])
    end

    test "a released movie TMDB has no date for does not wait" do
      assert %{available?: true} =
               MinimumAvailability.status(
                 movie(%{status: "Released"}),
                 "released",
                 ~D[2031-01-01]
               )
    end

    test "returns a Status struct" do
      assert %MinimumAvailability.Status{level: "released"} =
               MinimumAvailability.status(movie(%{}), "released", ~D[2031-01-01])
    end

    test "a movie with nothing to wait for is available" do
      assert %{eligible_on: nil, available?: true} =
               MinimumAvailability.status(movie(%{}), "released", ~D[2031-01-01])
    end
  end
end
