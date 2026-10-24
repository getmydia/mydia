defmodule MydiaWeb.DownloadsLive.PathsTest do
  use ExUnit.Case, async: true

  alias MydiaWeb.DownloadsLive.{Filters, Paths, Summary, Tab}

  defp assigns(overrides \\ %{}) do
    Map.merge(
      %{
        active_tab: :downloads,
        view: :active,
        drawer_id: nil,
        filters: %Filters{},
        tab_counts: %{downloads: 0, issues: 0},
        summary: %Summary{},
        scan: %{external: []}
      },
      overrides
    )
  end

  describe "downloads_path/2" do
    test "omits defaults" do
      assert Paths.downloads_path(assigns(), []) == "/downloads"
    end

    test "includes a non-default view" do
      assert Paths.downloads_path(assigns(), view: :imported) == "/downloads?view=imported"
    end
  end

  describe "tabs/1" do
    test "links keep the search and drop the status and view" do
      state =
        assigns(%{
          view: :imported,
          filters: %Filters{q: "show", status: "failed"}
        })

      assert [
               %Tab{key: :downloads} = downloads,
               %Tab{key: :issues} = issues,
               %Tab{key: :external}
             ] =
               Paths.tabs(state)

      assert downloads.href == "/downloads?q=show"
      assert issues.href == "/downloads?tab=issues&q=show"
    end
  end

  describe "kind" do
    test "is carried in the URL and dropped by tab links" do
      state = assigns(%{active_tab: :issues, filters: %Filters{kind: :missing}})

      assert Paths.downloads_path(state, []) == "/downloads?tab=issues&kind=missing"
      refute Enum.any?(Paths.tabs(state), &String.contains?(&1.href, "kind="))
    end
  end
end
