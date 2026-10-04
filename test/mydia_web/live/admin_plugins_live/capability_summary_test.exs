defmodule MydiaWeb.AdminPluginsLive.CapabilitySummaryTest do
  use ExUnit.Case, async: true

  alias Mydia.Plugins.Manifest
  alias MydiaWeb.AdminPluginsLive.CapabilitySummary
  alias MydiaWeb.AdminPluginsLive.CapabilitySummary.Group

  @plex %{
    "events:subscribe" => ["media_file.imported", "playback.finished"],
    "net:http" => ["plex.tv"],
    "state:kv" => [],
    "data:read" => ["playback_progress"],
    "surfaces:write" => ["playback:watched"],
    "users:connections" => [],
    "schedule:interval" => []
  }

  defp group(summary, key), do: Enum.find(summary.groups, &(&1.key == key))

  defp labels(nil), do: []
  defp labels(%Group{lines: lines}), do: Enum.map(lines, & &1.label)

  defp all_lines(summary), do: Enum.flat_map(summary.groups, & &1.lines) ++ summary.also

  describe "build/2" do
    test "groups a Plex-shaped manifest by effect" do
      summary = CapabilitySummary.build(@plex)

      assert Enum.map(summary.groups, & &1.key) == [:talks_to, :can_see, :can_change]
      assert labels(group(summary, :talks_to)) == ["plex.tv"]
      assert labels(group(summary, :can_see)) == ["Watch progress", "Accounts people link to it"]
      assert labels(group(summary, :can_change)) == ["Mark items watched"]

      assert Enum.map(summary.also, & &1.label) == [
               "reacts to new imports and finished playback",
               "runs on a schedule",
               "keeps its own storage"
             ]
    end

    test "only Talks to is emphasized" do
      summary = CapabilitySummary.build(@plex)
      assert [%Group{key: :talks_to}] = Enum.filter(summary.groups, & &1.emphasized?)
    end

    test "page, shelf and search land in their groups" do
      summary =
        CapabilitySummary.build(%{
          "surfaces:page" => [],
          "surfaces:shelf" => [],
          "data:search" => []
        })

      assert labels(group(summary, :adds)) == [
               "Its own page",
               "Suggestions on each person's Home page"
             ]

      assert labels(group(summary, :can_see)) == ["Search your library as the person using it"]
    end

    test "one Talks to line per host, private hosts called out" do
      summary =
        CapabilitySummary.build(%{
          "net:http" => ["api.simkl.com", "simkl.com"],
          "net:private" => ["ollama.lan"]
        })

      assert labels(group(summary, :talks_to)) == [
               "api.simkl.com",
               "simkl.com",
               "ollama.lan (private network)"
             ]
    end

    test "host-granting settings fields add a Talks to line" do
      schema = [
        %{"key" => "server_url", "label" => "Server URL", "type" => "url", "grants_host" => true},
        %{"key" => "token", "label" => "Token", "type" => "secret"}
      ]

      summary = CapabilitySummary.build(%{"net:http" => ["plex.tv"]}, settings_schema: schema)

      assert labels(group(summary, :talks_to)) == [
               "plex.tv",
               "The server you enter in Server URL"
             ]
    end

    test "a host-granting field with no label is named by its key" do
      schema = [%{"key" => "server_url", "type" => "url", "grants_host" => true}]
      summary = CapabilitySummary.build(%{}, settings_schema: schema)

      assert labels(group(summary, :talks_to)) == ["The server you enter in server_url"]
    end

    test "event phrases join with one event and with three" do
      one = CapabilitySummary.build(%{"events:subscribe" => ["media_item.added"]})
      assert Enum.map(one.also, & &1.label) == ["reacts to new titles"]

      three =
        CapabilitySummary.build(%{
          "events:subscribe" => ["media_item.added", "media_item.updated", "media_item.removed"]
        })

      assert Enum.map(three.also, & &1.label) == [
               "reacts to new titles, title updates and removed titles"
             ]
    end

    test "marks only the ungranted values as new" do
      requested = %{
        "net:http" => ["api.simkl.com"],
        "surfaces:write" => ["playback:watched", "collections:favorite"],
        "state:kv" => []
      }

      new = %{"surfaces:write" => ["collections:favorite"], "state:kv" => []}
      summary = CapabilitySummary.build(requested, new: new)

      assert summary |> all_lines() |> Enum.filter(& &1.new?) |> Enum.map(& &1.label) ==
               ["Favorite items", "keeps its own storage"]

      assert CapabilitySummary.new_count(summary) == 2
    end

    test "an empty set has no groups and no footer" do
      assert %CapabilitySummary{groups: [], also: []} = CapabilitySummary.build(%{})
    end

    test "an unknown class falls back to its raw name rather than disappearing" do
      summary = CapabilitySummary.build(%{"made:up" => ["x"]})
      assert Enum.map(summary.also, & &1.label) == ["made:up x"]
    end
  end

  describe "vocabulary coverage" do
    test "every data:read namespace has a label" do
      for ns <- Manifest.data_namespaces() do
        refute CapabilitySummary.data_label(ns) == ns, "no label for data:read #{ns}"
      end
    end

    test "every write surface has a label" do
      for surface <- Manifest.write_surfaces() do
        refute CapabilitySummary.surface_label(surface) == surface,
               "no label for surfaces:write #{surface}"
      end
    end

    test "every catalog event has a phrase" do
      for event <- Manifest.event_catalog() do
        refute CapabilitySummary.event_phrase(event) == event, "no phrase for #{event}"
      end
    end

    test "every known class renders with a host-owned label" do
      for class <- Manifest.known_classes() do
        labels =
          %{class => sample_values(class)}
          |> CapabilitySummary.build()
          |> all_lines()
          |> Enum.map(& &1.label)

        assert labels != [], "#{class} rendered nothing"
        refute Enum.any?(labels, &String.starts_with?(&1, class)), "#{class} fell back to raw"
      end
    end
  end

  describe "flat_labels/1" do
    test "lists every line label in display order" do
      assert CapabilitySummary.flat_labels(%{
               "data:read" => ["media_item"],
               "events:subscribe" => ["download.completed"]
             }) == ["Media items", "reacts to finished downloads"]
    end
  end

  defp sample_values("events:subscribe"), do: ["media_item.added"]
  defp sample_values("net:http"), do: ["example.com"]
  defp sample_values("data:read"), do: ["media_item"]
  defp sample_values("surfaces:write"), do: ["media:add"]
  defp sample_values(_), do: []
end
