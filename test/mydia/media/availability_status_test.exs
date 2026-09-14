defmodule Mydia.Media.AvailabilityStatusTest do
  use ExUnit.Case, async: true

  alias Mydia.Media.AvailabilityStatus

  @states [:missing, :partial, :downloaded, :downloading, :upcoming, :tba]

  describe "color/1" do
    test "returns the solid badge class when monitored" do
      status = %AvailabilityStatus{state: :missing, monitored: true}

      assert AvailabilityStatus.color(status) == "badge-error"
    end

    test "keeps the hue but drops the weight when unmonitored" do
      status = %AvailabilityStatus{state: :missing, monitored: false}

      assert AvailabilityStatus.color(status) == "badge-error badge-outline opacity-60"
    end

    test "does not repeat badge-outline for an unmonitored upcoming item" do
      status = %AvailabilityStatus{state: :upcoming, monitored: false}

      assert AvailabilityStatus.color(status) == "badge-outline opacity-60"
    end
  end

  describe "icon/1" do
    test "uses the same icon whether or not the item is monitored" do
      monitored = %AvailabilityStatus{state: :missing, monitored: true}
      unmonitored = %AvailabilityStatus{state: :missing, monitored: false}

      assert AvailabilityStatus.icon(monitored) == "hero-exclamation-circle"
      assert AvailabilityStatus.icon(unmonitored) == "hero-exclamation-circle"
    end

    test "never returns the eye-slash icon" do
      for state <- @states, monitored <- [true, false] do
        status = %AvailabilityStatus{state: state, monitored: monitored}

        refute AvailabilityStatus.icon(status) == "hero-eye-slash"
      end
    end
  end

  describe "label/1" do
    test "returns the plain label when monitored" do
      status = %AvailabilityStatus{state: :missing, monitored: true}

      assert AvailabilityStatus.label(status) == "Missing"
    end

    test "notes the monitoring state when unmonitored" do
      status = %AvailabilityStatus{state: :downloaded, monitored: false}

      assert AvailabilityStatus.label(status) == "Downloaded · Not monitored"
    end
  end

  test "every state has a colour, an icon and a label" do
    for state <- @states, monitored <- [true, false] do
      status = %AvailabilityStatus{state: state, monitored: monitored}

      assert is_binary(AvailabilityStatus.color(status))
      assert is_binary(AvailabilityStatus.icon(status))
      assert is_binary(AvailabilityStatus.label(status))
    end
  end

  test "state and monitored are both required" do
    assert_raise ArgumentError, fn ->
      struct!(AvailabilityStatus, state: :missing)
    end
  end

  describe "for_movie/3" do
    test "a file wins over an active download" do
      assert %AvailabilityStatus{state: :downloaded, monitored: true, file_count: 2} =
               AvailabilityStatus.for_movie(2, true, true)
    end

    test "an active download with no file is downloading" do
      assert %AvailabilityStatus{state: :downloading, monitored: false, file_count: 0} =
               AvailabilityStatus.for_movie(0, true, false)
    end

    test "nothing on disk and nothing downloading is missing" do
      assert %AvailabilityStatus{state: :missing, file_count: 0} =
               AvailabilityStatus.for_movie(0, false, true)
    end
  end

  describe "for_series/3" do
    defp counts(total, downloaded, downloading, upcoming) do
      %{total: total, downloaded: downloaded, downloading: downloading, upcoming: upcoming}
    end

    test "classifies over monitored episodes when there are any" do
      status = AvailabilityStatus.for_series(counts(5, 5, 0, 0), counts(2, 1, 0, 0), true)

      assert %AvailabilityStatus{state: :partial, monitored: true, downloaded: 1, total: 2} =
               status
    end

    test "falls back to every episode when none is monitored, and mutes the show" do
      status = AvailabilityStatus.for_series(counts(3, 3, 0, 0), counts(0, 0, 0, 0), true)

      assert %AvailabilityStatus{state: :downloaded, monitored: false, downloaded: 3, total: 3} =
               status
    end

    test "a show with no episodes keeps its own monitored flag and is missing" do
      status = AvailabilityStatus.for_series(counts(0, 0, 0, 0), counts(0, 0, 0, 0), true)

      assert %AvailabilityStatus{state: :missing, monitored: true, downloaded: 0, total: 0} =
               status
    end

    test "state precedence: downloaded, downloading, upcoming, partial, missing" do
      none = counts(0, 0, 0, 0)

      assert AvailabilityStatus.for_series(counts(2, 2, 1, 2), none, false).state == :downloaded
      assert AvailabilityStatus.for_series(counts(2, 1, 1, 2), none, false).state == :downloading
      assert AvailabilityStatus.for_series(counts(2, 1, 0, 2), none, false).state == :upcoming
      assert AvailabilityStatus.for_series(counts(2, 1, 0, 1), none, false).state == :partial
      assert AvailabilityStatus.for_series(counts(2, 0, 0, 1), none, false).state == :missing
    end
  end
end
