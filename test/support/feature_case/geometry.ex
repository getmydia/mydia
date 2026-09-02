defmodule MydiaWeb.FeatureCase.Geometry do
  @moduledoc """
  Layout assertions for Wallaby feature tests.

  Asserts facts about the rendered box rather than comparing screenshots.
  Deterministic, needs no baseline images, and immune to font rendering
  differences between a NixOS dev box and an ubuntu-latest CI runner.

  The failure messages name the offending element, so a regression reads as
  "#request-modal .btn-primary is covered by nav.dock" rather than
  "400 pixels changed".

  Built on `Wallaby.Browser.execute_script/4`, whose callback runs
  synchronously in the calling process and receives the script's return
  value. (`execute_script/3` discards it, which is why the callback form is
  used throughout.)
  """

  import ExUnit.Assertions

  @sample_divisions 4

  @doc """
  Asserts nothing is painted on top of `selector`.

  Samples a #{@sample_divisions - 1}x#{@sample_divisions - 1} grid across the
  element's bounding rect and calls `document.elementFromPoint` at each point.
  Any hit that is neither the element nor a descendant of it is a cover.
  """
  def refute_covered(session, selector) do
    case eval(session, covering_script(), [selector, @sample_divisions]) do
      "__missing__" ->
        flunk("refute_covered/2: no element matched #{inspect(selector)}")

      "__zero_size__" ->
        flunk(
          "refute_covered/2: #{inspect(selector)} has zero width or height, so nothing can be sampled"
        )

      [] ->
        session

      covering when is_list(covering) ->
        flunk("""
        Expected #{inspect(selector)} to be unobstructed, but it is covered by:

          #{Enum.join(covering, "\n  ")}

        Sampled a #{@sample_divisions - 1}x#{@sample_divisions - 1} grid across its bounding rect.
        """)
    end
  end

  @doc """
  Asserts the element's bounding rect lies within the viewport.
  """
  def assert_in_viewport(session, selector) do
    case eval(session, viewport_script(), [selector]) do
      "__missing__" ->
        flunk("assert_in_viewport/2: no element matched #{inspect(selector)}")

      %{"inside" => true} ->
        session

      %{"rect" => rect, "viewport" => viewport} ->
        flunk("""
        Expected #{inspect(selector)} to be inside the viewport.

          element:  #{inspect(rect)}
          viewport: #{inspect(viewport)}
        """)
    end
  end

  @doc """
  Asserts `selector_a` and `selector_b` have the same rendered height, within
  `tolerance_px`.

  Built for skeleton/real card height parity: a placeholder that visually
  promises to reserve a real element's height must actually do so, or the
  page collapses and re-expands once real content replaces it. Compares the
  first match of each selector.

  `tolerance_px` defaults to 1, deliberately small. Sub-pixel layout
  differences are normal and a 0-tolerance assertion would be flaky, but the
  regression this helper exists to catch was 12px, so 1px cannot hide it.
  """
  def assert_same_height(session, selector_a, selector_b, tolerance_px \\ 1) do
    case eval(session, same_height_script(), [selector_a, selector_b]) do
      "__missing_a__" ->
        flunk("assert_same_height/4: no element matched #{inspect(selector_a)}")

      "__missing_b__" ->
        flunk("assert_same_height/4: no element matched #{inspect(selector_b)}")

      "__zero_size_a__" ->
        flunk(
          "assert_same_height/4: #{inspect(selector_a)} has zero height, so there is nothing to compare"
        )

      "__zero_size_b__" ->
        flunk(
          "assert_same_height/4: #{inspect(selector_b)} has zero height, so there is nothing to compare"
        )

      %{"a" => height_a, "b" => height_b} ->
        delta = abs(height_a - height_b)

        if delta <= tolerance_px do
          session
        else
          flunk(
            "#{selector_a} is #{format_px(height_a)}px but #{selector_b} is " <>
              "#{format_px(height_b)}px (delta #{format_px(delta)}px, tolerance #{tolerance_px}px)"
          )
        end
    end
  end

  @doc """
  Asserts the element is not clipped by its nearest scrollable ancestor.
  """
  def refute_clipped(session, selector) do
    case eval(session, clipping_script(), [selector]) do
      "__missing__" ->
        flunk("refute_clipped/2: no element matched #{inspect(selector)}")

      %{"clipped" => false} ->
        session

      %{"rect" => rect, "container" => container, "container_rect" => container_rect} ->
        flunk("""
        Expected #{inspect(selector)} not to be clipped by its scroll container.

          element:   #{inspect(rect)}
          container: #{container} #{inspect(container_rect)}
        """)
    end
  end

  # Defined once in MydiaWeb.FeatureCase. Called fully qualified because
  # this module is imported into the test, not the other way round.
  defp eval(session, script, args) do
    MydiaWeb.FeatureCase.eval_js(session, script, args)
  end

  defp covering_script do
    """
    var selector = arguments[0];
    var divisions = arguments[1];
    var el = document.querySelector(selector);
    if (!el) { return '__missing__'; }

    var r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) { return '__zero_size__'; }

    function describe(node) {
      var out = node.tagName.toLowerCase();
      if (node.id) { out += '#' + node.id; }
      if (node.className && typeof node.className === 'string') {
        var classes = node.className.trim().split(/\\s+/).filter(Boolean);
        if (classes.length) { out += '.' + classes.join('.'); }
      }
      return out;
    }

    var covering = [];
    for (var i = 1; i < divisions; i++) {
      for (var j = 1; j < divisions; j++) {
        var x = r.left + (r.width * i) / divisions;
        var y = r.top + (r.height * j) / divisions;
        var hit = document.elementFromPoint(x, y);
        if (hit && hit !== el && !el.contains(hit)) {
          var desc = describe(hit);
          if (covering.indexOf(desc) === -1) { covering.push(desc); }
        }
      }
    }
    return covering;
    """
  end

  defp same_height_script do
    """
    var selectorA = arguments[0];
    var selectorB = arguments[1];

    var elA = document.querySelector(selectorA);
    if (!elA) { return '__missing_a__'; }

    var elB = document.querySelector(selectorB);
    if (!elB) { return '__missing_b__'; }

    var heightA = elA.getBoundingClientRect().height;
    if (heightA === 0) { return '__zero_size_a__'; }

    var heightB = elB.getBoundingClientRect().height;
    if (heightB === 0) { return '__zero_size_b__'; }

    return {a: heightA, b: heightB};
    """
  end

  # Renders a pixel measurement without a spurious ".0" (200, not 200.0) while
  # keeping real sub-pixel deltas visible (341.5).
  defp format_px(value) when is_integer(value), do: Integer.to_string(value)

  defp format_px(value) when is_float(value) do
    rounded = Float.round(value, 1)

    if rounded == trunc(rounded) do
      rounded |> trunc() |> Integer.to_string()
    else
      Float.to_string(rounded)
    end
  end

  defp viewport_script do
    """
    var el = document.querySelector(arguments[0]);
    if (!el) { return '__missing__'; }

    var r = el.getBoundingClientRect();
    var vw = document.documentElement.clientWidth;
    var vh = document.documentElement.clientHeight;
    var inside = r.top >= 0 && r.left >= 0 && r.bottom <= vh && r.right <= vw;

    return {
      inside: inside,
      rect: {top: r.top, left: r.left, bottom: r.bottom, right: r.right},
      viewport: {width: vw, height: vh}
    };
    """
  end

  defp clipping_script do
    """
    var el = document.querySelector(arguments[0]);
    if (!el) { return '__missing__'; }

    function scrollParent(node) {
      var parent = node.parentElement;
      while (parent && parent !== document.body) {
        var style = window.getComputedStyle(parent);
        var overflow = style.overflow + style.overflowX + style.overflowY;
        if (/(auto|scroll|hidden)/.test(overflow)) { return parent; }
        parent = parent.parentElement;
      }
      return document.documentElement;
    }

    function describe(node) {
      var out = node.tagName.toLowerCase();
      if (node.id) { out += '#' + node.id; }
      return out;
    }

    var container = scrollParent(el);
    var r = el.getBoundingClientRect();
    var c = container.getBoundingClientRect();
    var clipped = r.left < c.left - 1 || r.right > c.right + 1 ||
                  r.top < c.top - 1 || r.bottom > c.bottom + 1;

    return {
      clipped: clipped,
      rect: {top: r.top, left: r.left, bottom: r.bottom, right: r.right},
      container: describe(container),
      container_rect: {top: c.top, left: c.left, bottom: c.bottom, right: c.right}
    };
    """
  end
end
