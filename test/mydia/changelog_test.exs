defmodule Mydia.ChangelogTest do
  use ExUnit.Case, async: true

  alias Mydia.Changelog
  alias Mydia.Changelog.Entry

  defp entry(version_string) do
    %Entry{
      version: Version.parse!(version_string),
      version_string: version_string,
      html: "<p>#{version_string}</p>"
    }
  end

  defp fixtures do
    [entry("0.13.0"), entry("0.12.0"), entry("0.11.1"), entry("0.11.0")]
  end

  describe "unseen/2" do
    test "returns nothing when the stored version is the newest" do
      assert Changelog.unseen(fixtures(), "0.13.0") == []
    end

    test "returns only the newer entry when one release behind" do
      assert Enum.map(Changelog.unseen(fixtures(), "0.12.0"), & &1.version_string) == ["0.13.0"]
    end

    test "returns every newer entry, newest first, when several behind" do
      assert Enum.map(Changelog.unseen(fixtures(), "0.11.0"), & &1.version_string) ==
               ["0.13.0", "0.12.0", "0.11.1"]
    end

    test "returns nothing when the stored version is newer than anything bundled" do
      assert Changelog.unseen(fixtures(), "0.14.0") == []
    end

    test "returns nothing for nil" do
      assert Changelog.unseen(fixtures(), nil) == []
    end

    test "returns nothing for an unparseable stored value" do
      assert Changelog.unseen(fixtures(), "not-a-version") == []
      assert Changelog.unseen(fixtures(), "v0.12.0") == []
    end

    test "returns nothing when no entries are bundled" do
      assert Changelog.unseen([], "0.12.0") == []
    end

    test "treats a prerelease as older than its stable release" do
      assert Enum.map(Changelog.unseen(fixtures(), "0.13.0-beta.1"), & &1.version_string) ==
               ["0.13.0"]
    end
  end

  describe "entries/0 and latest/0" do
    test "entries are sorted newest first" do
      versions = Enum.map(Changelog.entries(), & &1.version)
      assert versions == Enum.sort(versions, {:desc, Version})
    end

    test "latest/0 agrees with the head of entries/0" do
      entries = Changelog.entries()

      expected =
        case List.first(entries) do
          nil -> nil
          %Entry{version_string: version_string} -> version_string
        end

      assert Changelog.latest() == expected
    end
  end
end
