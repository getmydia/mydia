defmodule MydiaWeb.Features.AlphaJumpPickerTest do
  @moduledoc """
  The phone letter picker must jump again when the same letter is chosen twice.

  A focused `<select>` keeps the user's value across a LiveView patch, so the
  picker is rebuilt under a new id after each jump. LiveViewTest cannot see
  that (it has no morphdom and no focus), so this drives a real browser.
  """
  use MydiaWeb.FeatureCase, async: false

  @moduletag :feature

  setup do
    for title <- ["Amber Lantern", "Harbor Compass", "Quiet Orchard", "Velvet Harbor"] do
      insert(:media_item, type: "movie", title: title)
    end

    :ok
  end

  defp picker_value(session) do
    eval_js(session, """
    var el = document.querySelector('#alpha-jump-picker select');
    return el ? el.value : '__missing__';
    """)
  end

  defp choose(session, letter) do
    click(session, Query.css("#alpha-jump-picker option[value=#{letter}]"))
  end

  defp current_url_letter(session) do
    session |> current_url() |> URI.parse() |> Map.get(:query, "") |> Kernel.||("")
  end

  defp wait_until(description, fun) do
    eventually(fn -> if fun.(), do: {:ok, true}, else: :error end, description: description)
  end

  test "choosing the same letter twice jumps both times", %{session: session} do
    login_as_admin(session)

    session
    |> resize_window(375, 800)
    |> visit_liveview("/movies")
    |> assert_has(Query.css("#alpha-jump-picker select"))

    choose(session, "h")
    wait_until("URL at letter h", fn -> current_url_letter(session) =~ "letter=h" end)

    # The select was rebuilt, so the placeholder is back and the same letter
    # can be chosen again. A kept "h" here is the bug.
    wait_until("picker back at its placeholder", fn -> picker_value(session) == "" end)

    # Move away, then back to H.
    choose(session, "v")
    wait_until("URL at letter v", fn -> current_url_letter(session) =~ "letter=v" end)
    wait_until("picker back at its placeholder", fn -> picker_value(session) == "" end)

    choose(session, "v")
    # Same letter as the URL: the server scrolls instead of patching. Count it.
    eval_js(
      session,
      "window.__scrolled = 0; window.__letter = null; window.addEventListener('phx:alpha_jump:scroll_top', function (e) { window.__scrolled += 1; window.__letter = e.detail && e.detail.letter; }); return true;"
    )

    choose(session, "v")

    wait_until("second pick of the same letter to jump", fn ->
      eval_js(session, "return window.__scrolled;") >= 1
    end)

    # The push names the letter, so the client lands on its first card
    # instead of the list's top, which load_previous may have moved. (The
    # four-title fixture is too short to scroll, so the landing itself is not
    # measurable here.)
    assert eval_js(session, "return window.__letter;") == "v"
  end
end
