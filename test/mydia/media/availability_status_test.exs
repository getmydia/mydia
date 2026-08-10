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
end
