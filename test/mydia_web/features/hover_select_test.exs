defmodule MydiaWeb.Features.HoverSelectTest do
  @moduledoc """
  Starting bulk selection from a library card's hover checkbox, in a real
  browser.

  `Phoenix.LiveViewTest` covers the `start_selection` event. It cannot run the
  browser half: the `mydia:start-selection` listener that outlines the clicked
  card, which the server cannot do because streamed cards never re-render from
  assigns alone, and the `MediaSelection` hook that removes outlines when
  selection mode ends.
  """
  use MydiaWeb.FeatureCase, async: false

  @moduletag :feature

  setup do
    held = insert(:media_item, type: "movie", title: "Cinder Almanac")
    other = insert(:media_item, type: "movie", title: "Lowtide Registry")

    %{held: held, other: other}
  end

  defp marked_ids(session) do
    eval_js(session, """
    return Array.from(document.querySelectorAll('#media-items [data-selected="true"]'))
      .map(function (el) { return el.id; });
    """)
  end

  defp await_marked(session, expected) do
    eventually(
      fn ->
        case marked_ids(session) do
          ^expected -> {:ok, expected}
          _other -> :error
        end
      end,
      description: "the outlined cards to be #{inspect(expected)}"
    )
  end

  # Headless Chrome reports `(hover: none)`, and Tailwind emits `group-hover`
  # inside `@media (hover: hover)`, so the checkbox is never revealed here and
  # a WebDriver click finds nothing visible to click. A script click still runs
  # the button's phx-click, the start_selection push and the
  # mydia:start-selection dispatch, which is the browser behavior under test.
  defp start_selection_from_card(session, item) do
    session
    |> resize_window(1400, 1000)
    |> visit_liveview("/movies")

    session
    |> js_click("#select-from-card-#{item.id}")
    |> assert_has(Query.css("#media-items.selection-mode"))
  end

  test "clicking a card's hover checkbox outlines that card and stays on the page",
       %{session: session, held: held} do
    login_as_admin(session)
    start_selection_from_card(session, held)

    assert await_marked(session, ["grid-item-#{held.id}"]) == ["grid-item-#{held.id}"]
    assert_path(session, "/movies")
  end

  test "pressing Escape removes the outline the checkbox added",
       %{session: session, held: held} do
    login_as_admin(session)
    start_selection_from_card(session, held)
    await_marked(session, ["grid-item-#{held.id}"])

    send_keys(session, [:escape])

    # refute_has checks once and does not wait for an element to go away, so it
    # fails before the server's reply lands. assert_has retries until found.
    assert_has(session, Query.css("#media-items:not(.selection-mode)"))
    assert await_marked(session, []) == []
  end

  test "leaving selection with the header Select button removes the outline",
       %{session: session, held: held} do
    login_as_admin(session)
    start_selection_from_card(session, held)
    await_marked(session, ["grid-item-#{held.id}"])

    click(session, Query.css("#toggle-selection-mode"))

    assert_has(session, Query.css("#media-items:not(.selection-mode)"))
    assert await_marked(session, []) == []
  end
end
