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
  @long "Glass.Harbor.2019.Directors.Extended.Remastered.1080p.BluRay.REMUX.AVC.DTS-HD.MA.7.1-LONGRELEASEGROUP"
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
        },
        %{
          title: @long,
          seeders: 99_999,
          indexer: "Ashvale Commons",
          info_url: "https://tracker3.example/details/77"
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

  defp rect_js do
    """
    var r = function (el) { var b = el.getBoundingClientRect();
      return {l: b.left, r: b.right, t: b.top, b: b.bottom, w: b.width}; };
    """
  end

  defp open_dialog(session, movie, {w, h}) do
    login_as_admin(session)

    session
    |> resize_window(w, h)
    |> visit_liveview("/media/#{movie.id}")

    js_click(session, "#manual-search-button")
    assert Wallaby.Browser.has_css?(session, "#indexer-search-status[aria-busy='false']")
    session
  end

  # The row whose title contains `needle`, as {title_fits, seeds_overflow_px}.
  defp row_fit(session, needle) do
    eval_js(
      session,
      rect_js() <>
        """
        var needle = arguments[0];
        var t = Array.from(document.querySelectorAll("#manual-search-results-pane [title]"))
          .find(function (el) {
            return el.getAttribute("title") === needle && el.textContent.trim() === needle;
          });
        if (!t) return null;
        var row = t.closest("[id^='search-result-']");
        var seeds = row.querySelector("[id$='-seeds'] .badge");
        var cell = seeds.parentElement;
        return {
          title_fits: t.scrollHeight <= t.clientHeight + 1 && t.scrollWidth <= t.clientWidth + 1,
          seeds_overflow: Math.round(r(seeds).r - r(cell).r)
        };
        """,
      [needle]
    )
  end

  # A selector for the lg column's indexer badge of the row titled `@title`,
  # the merged one, so the checks do not depend on how the rows sort.
  defp title_row_badge(session) do
    id =
      eval_js(
        session,
        """
        var needle = arguments[0];
        var t = Array.from(document.querySelectorAll("#manual-search-results-pane [title]"))
          .find(function (el) {
            return el.getAttribute("title") === needle && el.textContent.trim() === needle;
          });
        if (!t) return null;
        var badge = t.closest("[id^='search-result-']").querySelector("[id$='-indexer-badge']");
        return badge ? badge.id : null;
        """,
        [@title]
      )

    assert is_binary(id), "no indexer badge in the row titled #{@title}"
    ~s([id="#{id}"])
  end

  # How far the lg column's indexer badge runs past the right edge of its
  # grid cell; positive is overflow into the download button.
  defp badge_overflow_px(session, badge_selector) do
    eval_js(
      session,
      """
      var badge = document.querySelector(arguments[0]);
      if (!badge) return null;
      var cell = badge.parentElement.getBoundingClientRect();
      return Math.round(badge.getBoundingClientRect().right - cell.right);
      """,
      [badge_selector]
    )
  end

  # Whether the focused element is inside the element matching `selector`.
  defp focus_in?(session, selector) do
    eval_js(
      session,
      """
      var root = document.querySelector(arguments[0]);
      return !!root && root.contains(document.activeElement);
      """,
      [selector]
    )
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

  # Ticks one checkbox of the filter form and waits until the server has
  # answered with a chip naming it. The checkbox is clicked by script, so it
  # works whether the drawer is open or closed. Each tick round-trips through
  # `filter_search`, and a click landing before the previous diff could be
  # undone by it, so waiting only
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
            ["manual-search-chip-#{dimension}", shows]
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

      badge = title_row_badge(session)
      overflow = badge_overflow_px(session, badge)

      assert is_integer(overflow) and overflow <= 0,
             "at #{unquote(w)}px the indexer badge ran #{inspect(overflow)}px past its column"

      js_click(session, badge)

      assert %{"links" => 4, "inside" => true} = open_menu(session),
             "at #{unquote(w)}px the merged badge's menu did not open fully on screen " <>
               "with a link per tracker"
    end
  end

  @tag :feature
  test "the dialog uses large screens", %{session: session, movie: movie} do
    open_dialog(session, movie, {2560, 1440})
    box = width_of(session, "#manual-search-modal .modal-box")
    assert box > 1152, "at 2560px the dialog was only #{box}px wide"
  end

  # Where the filter sheet is and whether it is showing, measured against the
  # dialog box.
  defp panel_state(session) do
    eval_js(
      session,
      rect_js() <>
        """
        var box = r(document.querySelector("#manual-search-modal .modal-box"));
        var el = document.getElementById("manual-search-filter-sheet");
        var p = r(el);
        var shown = p.w > 0 && getComputedStyle(el.parentElement).visibility !== "hidden";
        return {shown: shown,
                inside: p.l >= box.l - 1 && p.r <= box.r + 1 && p.t >= box.t - 1 && p.b <= box.b + 1};
        """
    )
  end

  # The drawer's accessibility state: the toggle, the Filters button's
  # `aria-expanded`, whether the results pane is `inert`, and the focused id.
  defp drawer_state(session) do
    eval_js(session, """
    var btn = document.getElementById("manual-search-filters-button");
    return {
      checked: document.getElementById("manual-search-filter-toggle").checked,
      expanded: btn.getAttribute("aria-expanded"),
      inert: document.getElementById("manual-search-results-pane").hasAttribute("inert"),
      focus: document.activeElement && document.activeElement.id
    };
    """)
  end

  defp open_drawer_settled(session) do
    js_click(session, "#manual-search-filters-button")

    eventually(
      fn ->
        case panel_state(session) do
          %{"shown" => true, "inside" => true} -> {:ok, true}
          _ -> :error
        end
      end,
      description: "the filter drawer to open and settle inside the dialog"
    )
  end

  for {w, h} <- [{1143, 800}, {1440, 900}, {390, 844}] do
    @tag :feature
    test "filters start closed and open inside the dialog at #{w}px", %{
      session: session,
      movie: movie
    } do
      open_dialog(session, movie, {unquote(w), unquote(h)})

      panel = fn -> panel_state(session) end

      assert %{"shown" => false} = panel.()

      assert %{"checked" => false, "expanded" => "false", "inert" => false} =
               drawer_state(session)

      js_click(session, "#manual-search-filters-button")

      # Opening moves keyboard focus into the panel, not past every result row.
      eventually(
        fn ->
          if focus_in?(session, "#manual-search-filter-sheet"), do: {:ok, true}, else: :error
        end,
        description: "focus to move into the filter panel"
      )

      # The sheet slides in, so it is measured only once it has settled.
      eventually(
        fn ->
          case panel.() do
            %{"shown" => true, "inside" => true} -> {:ok, true}
            _ -> :error
          end
        end,
        description: "the filter drawer to open and settle inside the dialog"
      )

      assert %{"inside" => true} = panel.()
      assert %{"checked" => true, "expanded" => "true", "inert" => true} = drawer_state(session)

      # A filter change patches the results behind the open drawer. The patch
      # must neither close it nor strip the JS-set `inert`.
      tick(session, "quality", "1080p", "quality", "1080")
      assert %{"shown" => true, "inside" => true} = panel.()
      assert %{"checked" => true, "expanded" => "true", "inert" => true} = drawer_state(session)

      # From `sm` up the sheet covers only part of the dialog, so the results
      # stay visible (dimmed) behind the overlay. Waits out the 300ms a phone
      # takes to hide them, so a regression cannot slip past an early read.
      if unquote(w) >= 640 do
        Process.sleep(600)

        assert eval_js(
                 session,
                 "return getComputedStyle(document.getElementById('manual-search-results-pane')).visibility;"
               ) == "visible"
      else
        # On a phone the sheet nearly fills the dialog, so the results leave
        # the tab order once it has slid in.
        eventually(
          fn ->
            visibility =
              eval_js(
                session,
                "return getComputedStyle(document.getElementById('manual-search-results-pane')).visibility;"
              )

            if visibility == "hidden", do: {:ok, true}, else: :error
          end,
          description: "the results pane to be hidden behind the sheet"
        )
      end

      js_click(session, "#manual-search-show-results")

      eventually(fn -> if panel.()["shown"], do: :error, else: {:ok, true} end,
        description: "the filter drawer to close"
      )

      # Closing hands focus back to the button that opened the drawer.
      assert %{"checked" => false, "expanded" => "false", "inert" => false} =
               state = drawer_state(session)

      assert state["focus"] == "manual-search-filters-button"
    end

    @tag :feature
    test "the overlay closes the drawer and restores its state at #{w}px", %{
      session: session,
      movie: movie
    } do
      open_dialog(session, movie, {unquote(w), unquote(h)})
      open_drawer_settled(session)
      assert %{"checked" => true, "expanded" => "true", "inert" => true} = drawer_state(session)

      # The overlay is a `<label for>`: its native activation unchecks the
      # toggle, and its `phx-click` does the rest.
      js_click(session, ".drawer-overlay")

      eventually(fn -> if panel_state(session)["shown"], do: :error, else: {:ok, true} end,
        description: "the filter drawer to close"
      )

      assert %{"checked" => false, "expanded" => "false", "inert" => false} =
               state = drawer_state(session)

      assert state["focus"] == "manual-search-filters-button"
    end
  end

  for {w, h} <- [{1143, 800}, {2560, 1440}] do
    @tag :feature
    test "a long release name shows in full and 99,999 seeders fit at #{w}px", %{
      session: session,
      movie: movie
    } do
      open_dialog(session, movie, {unquote(w), unquote(h)})

      assert %{"title_fits" => true, "seeds_overflow" => overflow} = row_fit(session, @long)
      assert overflow <= 0, "the seeds badge ran #{overflow}px past its column"
    end
  end

  # The no-profile seeders circle holds the arrow and the count; its contents
  # must stay inside the circle. Returns widths so a failure shows the margin.
  @tag :feature
  test "the seeders circle holds a five-character count", %{session: session, movie: movie} do
    open_dialog(session, movie, {390, 844})

    assert %{"content" => content, "circle" => circle, "text" => text} =
             eval_js(session, """
             var c = document.querySelector("[id$='-seeders-circle']");
             if (!c) return null;
             var range = document.createRange();
             range.selectNodeContents(c);
             var inner = range.getBoundingClientRect();
             var cb = c.getBoundingClientRect();
             return {content: Math.round(inner.width * 10) / 10,
                     circle: Math.round(cb.width * 10) / 10,
                     text: c.textContent.trim()};
             """),
           "no seeders circle rendered; the fixture has a quality profile"

    assert content <= circle - 4,
           "#{inspect(text)} and its arrow are #{content}px wide in a #{circle}px circle"
  end
end
