defmodule MydiaWeb.Features.ManualSearchLayoutTest do
  @moduledoc """
  The manual search dialog keeps its indexer status, filter chips and indexer
  badge legible from `lg` with every filter dimension active (#1311).

  Before the fix, at 1143px with four indexers ticked: the status summary
  beside the chips was about 80px wide, the indexer column's badge ran past
  its 9rem cell into the download button, and a merged release offered no
  way to open any tracker's page but the winner's.
  """
  use MydiaWeb.FeatureCase, async: false

  import Mydia.MediaFixtures, only: [media_item_fixture: 1]

  alias Mydia.IndexerMock
  alias Mydia.Settings

  @moduletag :feature

  @title "Glass.Harbor.2019.1080p.BluRay.x264-GROUP"
  @magnet "magnet:?xt=urn:btih:" <> String.duplicate("ab", 20)

  # Fictional trackers; the winner (most seeders) has the long name.
  @trackers [
    "The Westmarch Lantern Archive Network",
    "Saltmarsh Mirror",
    "Brinewater Exchange",
    "Ashvale Commons"
  ]

  # Below this the summary's "N results · done/total indexers" line wraps
  # word by word, which is what the report showed.
  @readable_px 300

  defp results do
    merged =
      for {tracker, i} <- Enum.with_index(@trackers) do
        %{
          title: @title,
          seeders: 50 - i,
          magnet_url: @magnet,
          indexer: tracker,
          info_url: "https://tracker#{i}.example/details/#{i}"
        }
      end

    merged ++
      [
        %{
          title: "Glass.Harbor.2019.2160p.WEB-DL.x265-GROUP",
          seeders: 20,
          indexer: "Saltmarsh Mirror",
          info_url: "https://tracker1.example/details/99"
        }
      ]
  end

  setup do
    Settings.list_indexer_configs()
    |> Enum.reject(&Settings.runtime_config?/1)
    |> Enum.each(&Settings.update_indexer_config(&1, %{enabled: false}))

    bypass = Bypass.open()
    IndexerMock.mock_prowlarr_all(bypass, results: results())

    {:ok, _indexer} =
      Settings.create_indexer_config(%{
        name: "Fictional Prowlarr",
        type: :prowlarr,
        base_url: "http://localhost:#{bypass.port}",
        api_key: "test-key",
        enabled: true
      })

    %{movie: media_item_fixture(%{type: "movie", title: "Glass Harbor", year: 2019})}
  end

  defp width_of(session, selector) do
    eval_js(
      session,
      """
      var el = document.querySelector(arguments[0]);
      return el ? Math.round(el.getBoundingClientRect().width) : -1;
      """,
      [selector]
    )
  end

  # How far the lg column's indexer badge runs past the right edge of its
  # grid cell; positive is overflow into the download button.
  defp badge_overflow_px(session) do
    eval_js(session, """
    var badge = document.querySelector("[id$='-indexer-badge']");
    if (!badge) return null;
    var cell = badge.parentElement.getBoundingClientRect();
    return Math.round(badge.getBoundingClientRect().right - cell.right);
    """)
  end

  defp open_menu(session) do
    eval_js(session, """
    var menu = document.querySelector("[id$='-indexer-badge-menu']:popover-open");
    if (!menu) return null;
    var r = menu.getBoundingClientRect();
    return {
      links: menu.querySelectorAll("a[href]").length,
      inside: r.left >= 0 && r.top >= 0 &&
              r.right <= window.innerWidth && r.bottom <= window.innerHeight
    };
    """)
  end

  # Ticks one sidebar checkbox and waits until the server has answered with a
  # chip naming it. Each tick round-trips through `filter_search`, and a click
  # landing before the previous diff could be undone by it, so waiting only
  # for the chip to exist (true from the first indexer on) is not enough.
  defp tick(session, field, value, dimension, shows) do
    js_click(
      session,
      ~s(#manual-search-filter-form input[name="#{field}[]"][value="#{value}"])
    )

    eventually(
      fn ->
        named =
          eval_js(
            session,
            """
            var chip = document.getElementById(arguments[0]);
            if (!chip) return false;
            return (chip.textContent + " " + (chip.title || "")).indexOf(arguments[1]) !== -1;
            """,
            ["manual-search-lg-chip-#{dimension}", shows]
          )

        if named, do: {:ok, true}, else: :error
      end,
      description: "the #{dimension} chip to name #{value}"
    )
  end

  for {w, h} <- [{1024, 768}, {1440, 900}] do
    @tag :feature
    test "status, chips and indexer badge stay legible at #{w}px", %{
      session: session,
      movie: movie
    } do
      login_as_admin(session)

      session
      |> resize_window(unquote(w), unquote(h))
      |> visit_liveview("/media/#{movie.id}")

      js_click(session, "#manual-search-button")
      assert Wallaby.Browser.has_css?(session, "#indexer-search-status[aria-busy='false']")

      for tracker <- @trackers, do: tick(session, "indexer", tracker, "indexer", tracker)

      # Every filter dimension active, each value one the merged 1080p release
      # carries, so it stays in the list to be measured. The first source and
      # codec options belong to the 2160p release and would filter it out.
      tick(session, "quality", "1080p", "quality", "1080")
      tick(session, "source", "BluRay", "source", "BluRay")
      tick(session, "codec", "AVC", "codec", "AVC")

      summary = width_of(session, "#indexer-search-status summary")

      assert summary >= @readable_px,
             "at #{unquote(w)}px the indexer status summary was #{summary}px wide"

      overflow = badge_overflow_px(session)

      assert is_integer(overflow) and overflow <= 0,
             "at #{unquote(w)}px the indexer badge ran #{inspect(overflow)}px past its column"

      js_click(session, "[id$='-indexer-badge']")

      assert %{"links" => 4, "inside" => true} = open_menu(session),
             "at #{unquote(w)}px the merged badge's menu did not open fully on screen " <>
               "with a link per tracker"
    end
  end
end
