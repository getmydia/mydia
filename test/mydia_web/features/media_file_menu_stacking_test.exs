defmodule MydiaWeb.Features.MediaFileMenuStackingTest do
  @moduledoc """
  The Media Files card's "More file actions" menu paints above the franchise
  rail that follows it (#1107).

  The menu opens downward out of the card and over the rail's poster cards,
  whose rating badges sit at `absolute z-10`. With the menu at `z-[1]` the
  badges come later in the DOM and win, so they showed through the open menu
  on phones. Only `elementFromPoint` over the open menu can see that; the
  class list cannot.
  """
  use MydiaWeb.FeatureCase, async: false

  import Mydia.MediaFixtures, only: [media_item_fixture: 1]

  alias Mydia.Metadata.Cache

  @moduletag :feature

  @tmdb_id 990_101

  setup do
    bypass = Bypass.open()
    collection_id = System.unique_integer([:positive])

    previous_metadata_relay_url = Application.get_env(:mydia, :metadata_relay_url)
    Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")
    Cache.clear()

    on_exit(fn ->
      case previous_metadata_relay_url do
        nil -> Application.delete_env(:mydia, :metadata_relay_url)
        value -> Application.put_env(:mydia, :metadata_relay_url, value)
      end

      Cache.clear()
    end)

    collection_path = "/tmdb/collections/#{collection_id}"

    # One catch-all handler (Bypass.expect/2 matches every route, and the
    # collection call guarantees it fires). Every other relay call the page
    # makes, recommendations among them, gets a fast 404 rather than an
    # unstubbed 500, which Req would retry with backoff.
    Bypass.expect(bypass, fn
      %{request_path: ^collection_path} = conn -> collection_response(conn, collection_id)
      conn -> Plug.Conn.resp(conn, 404, "")
    end)

    movie =
      media_item_fixture(%{
        title: "Brinewater",
        year: 2001,
        tmdb_id: @tmdb_id,
        metadata: %{
          "provider_id" => to_string(@tmdb_id),
          "provider" => "metadata_relay",
          "media_type" => "movie",
          "title" => "Brinewater",
          "collection_id" => collection_id,
          "collection_name" => "Brinewater Collection"
        }
      })

    # 2160p so the menu lists every pre-transcode resolution and is at its
    # tallest, reaching well into the rail below the card.
    file =
      insert(:media_file,
        episode: nil,
        media_item_id: movie.id,
        path: "/media/movies/Brinewater (2001)/Brinewater.2001.2160p.UHD.BluRay.mkv",
        resolution: "2160p",
        codec: "h265"
      )

    # Not `file:`, which ExUnit reserves in the test context.
    %{movie: movie, media_file: file}
  end

  # The rating badges are what covered the menu in the report, and they only
  # render for a positive vote_average.
  defp collection_response(conn, collection_id) do
    parts =
      for {id, title, vote} <- [
            {@tmdb_id, "Brinewater", 8.2},
            {@tmdb_id + 1, "Brinewater Rising", 8.0},
            {@tmdb_id + 2, "Brinewater Deep", 6.4}
          ] do
        %{
          "id" => id,
          "title" => title,
          "release_date" => "2001-01-01",
          "vote_average" => vote,
          "poster_path" => nil
        }
      end

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(
      200,
      Jason.encode!(%{"id" => collection_id, "name" => "Brinewater Collection", "parts" => parts})
    )
  end

  # Scrolls the trigger to just under the sticky header, so the menu opens
  # into the visible part of the viewport, then opens it the way a tap does:
  # by clicking the popovertarget trigger.
  defp open_file_menu(session, file) do
    eval_js(
      session,
      """
      var menu = document.getElementById(arguments[0]);
      var trigger = document.getElementById(arguments[1]);
      if (!menu || !trigger) { return '__missing__'; }
      window.scrollTo(0, window.scrollY + trigger.getBoundingClientRect().top - 120);
      trigger.click();
      return menu.matches(':popover-open') ? 'ok' : '__closed__';
      """,
      ["file-actions-menu-#{file.id}", "file-actions-more-#{file.id}"]
    )
  end

  # Hit-tests the centre of every overlap between the open menu and a rail
  # element that carries its own z-index (the badges and overlay buttons).
  # Geometry.refute_covered/2 samples a fixed 3x3 grid, which at 375px falls
  # between the 25px-tall badges and passes with the bug present.
  #
  # Returns "__no_overlap__" when nothing z-indexed overlaps the menu, so a
  # layout change that moves the rail out from under the menu fails loudly
  # rather than passing a probe that tests nothing.
  defp rail_elements_over_menu(session, file) do
    eval_js(
      session,
      """
      var menu = document.getElementById(arguments[0]);
      if (!menu) { return '__missing__'; }
      var m = menu.getBoundingClientRect();
      if (m.width === 0 || m.height === 0) { return '__closed__'; }

      function describe(node) {
        var out = node.tagName.toLowerCase();
        if (node.id) { out += '#' + node.id; }
        if (typeof node.className === 'string' && node.className.trim()) {
          out += '.' + node.className.trim().split(/\\s+/).join('.');
        }
        return out;
      }

      var overlaps = 0;
      var covering = [];
      var candidates = document.querySelectorAll('#franchise-section *');
      for (var i = 0; i < candidates.length; i++) {
        var el = candidates[i];
        if (getComputedStyle(el).zIndex === 'auto') { continue; }
        var r = el.getBoundingClientRect();
        var left = Math.max(r.left, m.left), right = Math.min(r.right, m.right);
        var top = Math.max(r.top, m.top), bottom = Math.min(r.bottom, m.bottom);
        if (right - left < 2 || bottom - top < 2) { continue; }

        overlaps++;
        var hit = document.elementFromPoint((left + right) / 2, (top + bottom) / 2);
        if (hit && hit !== menu && !menu.contains(hit)) {
          var desc = describe(hit);
          if (covering.indexOf(desc) === -1) { covering.push(desc); }
        }
      }

      return overlaps === 0 ? '__no_overlap__' : covering;
      """,
      ["file-actions-menu-#{file.id}"]
    )
  end

  # 375x812 is the phone width from the report. Wider layouts put the rail's
  # badges clear of the menu, so they cannot exercise this.
  @tag :feature
  test "the open menu paints above the franchise rail's badges at 375x812", ctx do
    %{session: session, movie: movie, media_file: file} = ctx

    login_as_admin(session)

    session
    |> resize_window(375, 812)
    |> visit_liveview("/media/#{movie.id}")
    |> assert_has(Query.css("#franchise-section"))

    assert open_file_menu(session, file) == "ok"

    assert rail_elements_over_menu(session, file) == [],
           "rail elements paint over the open file actions menu: " <>
             inspect(rail_elements_over_menu(session, file))
  end
end
