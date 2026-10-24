defmodule Mydia.TimeDisplayTest do
  use ExUnit.Case, async: true

  alias Mydia.Accounts.UserPreference
  alias Mydia.TimeDisplay

  describe "parse_time_zone/1" do
    test "accepts IANA names, links and the glibc leading colon" do
      assert TimeDisplay.parse_time_zone("Europe/Rome") == {:ok, "Europe/Rome"}
      assert TimeDisplay.parse_time_zone(":Europe/Rome") == {:ok, "Europe/Rome"}
      assert TimeDisplay.parse_time_zone(" America/New_York ") == {:ok, "America/New_York"}
      assert TimeDisplay.parse_time_zone("UTC") == {:ok, "UTC"}
    end

    test "rejects empty, POSIX rule strings and unknown names" do
      assert TimeDisplay.parse_time_zone(nil) == :error
      assert TimeDisplay.parse_time_zone("") == :error
      assert TimeDisplay.parse_time_zone("CET-1CEST,M3.5.0,M10.5.0/3") == :error
      assert TimeDisplay.parse_time_zone("Not/AZone") == :error
    end
  end

  describe "resolve/3" do
    test "nil preference uses the instance zone and a 12-hour clock" do
      assert TimeDisplay.resolve(nil, "Europe/Rome", "en") ==
               %TimeDisplay{time_zone: "Europe/Rome", clock: :h12}
    end

    test "the user's zone overrides the instance zone" do
      pref = %UserPreference{preferences: %{"time_zone" => "Asia/Tokyo"}}
      assert TimeDisplay.resolve(pref, "Europe/Rome", "en").time_zone == "Asia/Tokyo"
    end

    test "a stored zone tzdata does not know falls back to the instance zone" do
      pref = %UserPreference{preferences: %{"time_zone" => "Gone/Zone"}}
      assert TimeDisplay.resolve(pref, "Europe/Rome", "en").time_zone == "Europe/Rome"
    end

    test "auto clock follows the resolved locale" do
      pref = %UserPreference{preferences: %{}}
      assert TimeDisplay.resolve(pref, "Etc/UTC", "en").clock == :h12
      assert TimeDisplay.resolve(pref, "Etc/UTC", "it").clock == :h24
      assert TimeDisplay.resolve(nil, "Etc/UTC", "de").clock == :h24
      assert TimeDisplay.resolve(nil, "Etc/UTC", "en").clock == :h12
    end

    test "an explicit clock wins over the locale" do
      pref = %UserPreference{preferences: %{"clock_format" => "24"}}
      assert TimeDisplay.resolve(pref, "Etc/UTC", "en").clock == :h24

      pref = %UserPreference{preferences: %{"clock_format" => "12"}}
      assert TimeDisplay.resolve(pref, "Etc/UTC", "de").clock == :h12
    end
  end

  test "instance_time_zone/0 always returns a zone tzdata knows" do
    assert {:ok, _} = TimeDisplay.parse_time_zone(TimeDisplay.instance_time_zone())
  end
end
