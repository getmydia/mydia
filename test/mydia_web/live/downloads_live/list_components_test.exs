defmodule MydiaWeb.DownloadsLive.ListComponentsTest do
  use MydiaWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias MydiaWeb.DownloadsLive.{ListComponents, Tab}

  defp tabs do
    [
      %Tab{
        key: :downloads,
        label: "Downloads",
        icon: "hero-arrow-down-tray",
        href: "/downloads",
        count: 2,
        dot?: true
      },
      %Tab{
        key: :issues,
        label: "Issues",
        icon: "hero-exclamation-triangle",
        href: "/downloads?tab=issues",
        count: 3,
        tone: :error
      },
      %Tab{
        key: :external,
        label: "External",
        icon: "hero-inbox-stack",
        href: "/downloads?tab=external",
        count: 0
      }
    ]
  end

  defp render_tab_bar(active) do
    assigns = %{tabs: tabs(), active: active}

    ~H"""
    <ListComponents.tab_bar tabs={@tabs} active={@active}>
      <p id="panel-body">Body</p>
    </ListComponents.tab_bar>
    """
    |> rendered_to_string()
    |> LazyHTML.from_fragment()
  end

  describe "tab_bar/1" do
    test "marks only the active tab with aria-current and lifts it" do
      doc = render_tab_bar(:issues)

      assert doc |> LazyHTML.query("#downloads-tabs.tabs.tabs-lift") |> Enum.count() == 1

      assert doc |> LazyHTML.query("#downloads-tab-issues[aria-current='page']") |> Enum.count() ==
               1

      assert doc |> LazyHTML.query("[aria-current]") |> Enum.count() == 1
    end

    test "renders the panel right after the active tab and nowhere else" do
      doc = render_tab_bar(:issues)

      assert doc
             |> LazyHTML.query(
               "#downloads-tab-issues + #downloads-tab-panel.tab-content #panel-body"
             )
             |> Enum.count() == 1

      assert doc |> LazyHTML.query("#downloads-tab-panel") |> Enum.count() == 1
    end

    test "shows counts only when non-zero, red for error tone, and the stalled dot" do
      doc = render_tab_bar(:downloads)

      assert doc
             |> LazyHTML.query("#downloads-tab-downloads-count")
             |> LazyHTML.text()
             |> String.trim() == "2"

      assert doc |> LazyHTML.query("#downloads-tab-issues-count.badge-error") |> Enum.count() == 1
      assert doc |> LazyHTML.query("#downloads-tab-external-count") |> Enum.count() == 0

      assert doc
             |> LazyHTML.query("#downloads-tab-downloads-stalled.status-warning")
             |> Enum.count() == 1
    end

    test "tabs are patch links to their href" do
      doc = render_tab_bar(:downloads)

      assert doc
             |> LazyHTML.query(
               "a#downloads-tab-issues[href='/downloads?tab=issues'][data-phx-link='patch']"
             )
             |> Enum.count() == 1
    end
  end

  describe "empty_state/1" do
    test "renders the title, description and optional action" do
      assigns = %{}

      doc =
        ~H"""
        <ListComponents.empty_state icon="hero-funnel" title="No downloads match" description="Try again.">
          <:action><button id="act">Clear</button></:action>
        </ListComponents.empty_state>
        """
        |> rendered_to_string()
        |> LazyHTML.from_fragment()

      assert doc |> LazyHTML.query("#downloads-empty-state h3") |> LazyHTML.text() =~
               "No downloads match"

      assert doc |> LazyHTML.query("#downloads-empty-state #act") |> Enum.count() == 1
    end
  end
end
