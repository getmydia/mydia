defmodule MydiaWeb.Features.MobileLayoutSelfTest do
  @moduledoc """
  Tests the mobile layout checker itself against markup with a known defect
  and a known-good twin, so a failure here means the checker is broken rather
  than the UI. A checker that returns [] for everything fails the "fires"
  half of every case.
  """
  use MydiaWeb.FeatureCase, async: false

  @moduletag :feature
  # The /profile host page logs that no download client is configured.
  @moduletag :capture_log

  # Each case: {check, bad_html, good_html}. The fixture is rendered inside
  # #mlx, a 300px-wide box at the top left of a 320px viewport.
  @cases [
    {:inner_scroll,
     ~s|<div style="overflow-x:auto;width:200px"><div style="width:400px;height:10px"></div></div>|,
     ~s|<div data-scroll-rail style="overflow-x:auto;width:200px"><div style="width:400px;height:10px"></div></div>|},
    {:escapes_viewport, ~s|<div id="wide" style="width:500px;height:10px"></div>|,
     ~s|<div style="width:280px;height:10px"></div>|},
    {:small_target, ~s|<button style="width:16px;height:16px;padding:0">x</button>|,
     ~s|<button style="width:32px;height:32px;padding:0">x</button>|},
    {:overlapping_targets,
     ~s|<div style="position:relative;height:40px"><button style="position:absolute;left:0;width:40px;height:40px">a</button><button style="position:absolute;left:20px;width:40px;height:40px">b</button></div>|,
     ~s|<div style="display:flex;gap:4px"><button style="width:40px;height:40px">a</button><button style="width:40px;height:40px">b</button></div>|},
    {:clipped_text,
     ~s|<div style="overflow:hidden;white-space:nowrap;width:60px">A considerably long fictional label</div>|,
     ~s|<div style="overflow:hidden;white-space:nowrap;text-overflow:ellipsis;width:60px">A considerably long fictional label</div>|},
    {:clipped_text,
     ~s|<div style="overflow:hidden;white-space:nowrap;width:60px"><span>A considerably long fictional label</span></div>|,
     ~s|<div style="overflow:hidden;white-space:nowrap;text-overflow:ellipsis;width:60px"><span>A considerably long fictional label</span></div>|},
    {:tiny_text, ~s|<span style="font-size:10px">tiny</span>|,
     ~s|<span style="font-size:12px">fine</span>|},
    # Text cut by an overflow: hidden box is reported even when a nearer
    # ancestor is a scroller that does not itself cut it.
    {:clipped_text,
     ~s|<div style="overflow:hidden;width:60px"><div style="overflow-x:auto;width:max-content;white-space:nowrap">A considerably long fictional label</div></div>|,
     ~s|<div style="overflow:hidden;width:290px"><div style="overflow-x:auto;width:max-content;white-space:nowrap">A fictional label</div></div>|},
    # An ellipsis only renders where text cannot wrap: with normal wrapping a
    # long unbroken token is cut bare.
    {:clipped_text,
     ~s|<div style="overflow:hidden;text-overflow:ellipsis;width:60px">Considerablylongfictionalunbrokentoken</div>|,
     ~s|<div style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap;width:60px">Considerablylongfictionalunbrokentoken</div>|},
    # A flex container's text sits in an anonymous item, so its
    # text-overflow: ellipsis never renders and the cut is bare.
    {:clipped_text,
     ~s|<div style="display:flex;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;width:60px">A considerably long fictional label</div>|,
     ~s|<div style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap;width:60px">A considerably long fictional label</div>|},
    # overflow does not apply to an inline box: the block around it does the
    # cutting (see also "an inline box never takes the blame for a cut").
    {:clipped_text,
     ~s|<div style="overflow:hidden;white-space:nowrap;width:60px"><span style="overflow:hidden">A considerably long fictional label</span></div>|,
     ~s|<div style="overflow:hidden;white-space:nowrap;width:290px"><span style="overflow:hidden">A fictional label</span></div>|},
    # False positives found by the sweep. Each good fixture is the markup that
    # used to fire.
    #
    # The body of a closed <details> (the Changelog's entries) keeps a layout
    # box at a meaningless position but is never painted.
    {:escapes_viewport, ~s|<div style="width:500px;height:10px"></div>|,
     ~s|<details><summary>v1</summary><div style="width:500px;height:10px"></div></details>|},
    # Page content scrolls under a fixed dock or sticky header by design.
    {:overlapping_targets,
     ~s|<div style="position:relative;height:40px"><a href="#" style="position:absolute;left:0;display:block;width:200px;height:40px">a</a><a href="#" style="position:absolute;left:180px;display:block;width:40px;height:40px">b</a></div>|,
     ~s|<a href="#" style="display:block;width:200px;height:40px">a</a><nav style="position:fixed;top:0;left:0"><a href="#" style="display:block;width:40px;height:40px">d</a></nav>|},
    # A select box laid over a poster card's link sits wholly inside it.
    {:overlapping_targets,
     ~s|<div style="position:relative;height:200px"><a href="#" style="display:block;width:150px;height:200px">card</a><button style="position:absolute;top:8px;left:130px;width:32px;height:32px">s</button></div>|,
     ~s|<div style="position:relative;height:200px"><a href="#" style="display:block;width:150px;height:200px">card</a><button style="position:absolute;top:8px;left:8px;width:32px;height:32px">s</button></div>|},
    # The two exemptions above stay narrow: two targets in different fixed
    # layers (a floating button over the dock) still collide...
    {:overlapping_targets,
     ~s|<div style="position:fixed;top:0;left:0"><button style="width:40px;height:40px">a</button></div><div style="position:fixed;top:0;left:20px"><button style="width:40px;height:40px">b</button></div>|,
     ~s|<div style="position:fixed;top:0;left:0"><button style="width:40px;height:40px">a</button></div><div style="position:fixed;top:0;left:60px"><button style="width:40px;height:40px">b</button></div>|},
    # ...and so do two stacked targets of the same size.
    {:overlapping_targets,
     ~s|<div style="position:relative;height:40px"><button style="position:absolute;top:0;left:0;width:40px;height:40px">a</button><button style="position:absolute;top:0;left:0;width:40px;height:40px">b</button></div>|,
     ~s|<div style="position:relative;height:200px"><a href="#" style="display:block;width:150px;height:200px">card</a><button style="position:absolute;top:8px;left:8px;width:32px;height:32px">s</button></div>|},
    # A span inside a truncating line (the manual search dialog's subtitle) is
    # cut at the line's edge and escapes nothing.
    {:escapes_viewport,
     ~s|<p style="white-space:nowrap;width:200px"><span>A considerably long fictional subtitle for a fictional title that keeps going</span></p>|,
     ~s|<p style="overflow:hidden;white-space:nowrap;text-overflow:ellipsis;width:200px"><span>A considerably long fictional subtitle for a fictional title that keeps going</span></p>|},
    # A link scrolled out of its container (the drawer's nav, under the user
    # menu pinned below it) is not under the finger.
    {:overlapping_targets,
     ~s|<div style="position:relative;height:120px"><div style="height:40px"><a href="#" style="display:block;height:40px">one</a><a href="#" style="display:block;height:40px">two</a></div><button style="position:absolute;top:40px;left:0;width:280px;height:40px">menu</button></div>|,
     ~s|<div style="position:relative;height:120px"><div style="height:40px;overflow-y:auto"><a href="#" style="display:block;height:40px">one</a><a href="#" style="display:block;height:40px">two</a></div><button style="position:absolute;top:40px;left:0;width:280px;height:40px">menu</button></div>|},
    # A link inside a sentence of helper text in a <div> (Devices' "Remote
    # access is turned off" note) is WCAG 2.5.8's inline exception.
    {:small_target, ~s|<div style="font-size:12px"><a href="#">Enable it</a></div>|,
     ~s|<div style="font-size:12px">Remote access is turned off. <a href="#">Enable it</a></div>|},
    # Box overflow that hides no glyphs (a badge's padding, an unloaded lazy
    # image's alt box) is not clipped text.
    {:clipped_text,
     ~s|<div style="overflow:hidden;height:30px;line-height:20px"><div>One line</div><div>Second line</div></div>|,
     ~s|<div style="overflow:hidden;height:30px;line-height:20px"><div style="padding-bottom:30px">One line</div></div>|}
  ]

  setup %{session: session} do
    login_as_admin(session)
    Wallaby.Browser.resize_window(session, 320, 640)
    visit_liveview(session, "/profile")
    :ok
  end

  defp render_fixture(session, html) do
    eval_js(
      session,
      """
      var old = document.getElementById('mlx'); if (old) old.remove();
      var box = document.createElement('div');
      box.id = 'mlx';
      box.style.cssText = 'position:absolute;top:0;left:0;width:300px;z-index:9999;background:#fff;font-size:16px';
      box.innerHTML = arguments[0];
      document.body.appendChild(box);
      return true;
      """,
      [html]
    )
  end

  for {{check, bad, good}, n} <- Enum.with_index(@cases) do
    @tag :feature
    test "#{check} fires on the bad fixture (case #{n})", %{session: session} do
      render_fixture(session, unquote(bad))
      checks = session |> audit(scope: "#mlx") |> Enum.map(& &1.check)
      assert unquote(check) in checks
    end

    @tag :feature
    test "#{check} stays quiet on the good fixture (case #{n})", %{session: session} do
      render_fixture(session, unquote(good))
      # Nothing at all, not merely nothing of this check: a good fixture that
      # trips another rule would hide whether this one stays quiet.
      assert audit(session, scope: "#mlx") == []
    end
  end

  @tag :feature
  test "page_overflow fires when the document is wider than the viewport", %{session: session} do
    refute :page_overflow in Enum.map(audit(session), & &1.check)

    render_fixture(
      session,
      ~s|<div style="position:absolute;left:0;width:600px;height:5px"></div>|
    )

    assert :page_overflow in Enum.map(audit(session), & &1.check)
  end

  @tag :feature
  test "an inline box never takes the blame for a cut", %{session: session} do
    render_fixture(
      session,
      ~s|<div id="blk" style="overflow:hidden;white-space:nowrap;width:60px"><span id="inl" style="overflow:hidden">A considerably long fictional label</span></div>|
    )

    clipped = session |> audit(scope: "#mlx") |> Enum.filter(&(&1.check == :clipped_text))
    assert Enum.map(clipped, & &1.selector) == ["#blk"]
  end

  @tag :feature
  test "the scoped element itself is audited", %{session: session} do
    render_fixture(
      session,
      ~s|<button id="lone" style="width:16px;height:16px;padding:0">x</button>|
    )

    assert [%{check: :small_target, selector: "#lone"}] = audit(session, scope: "#lone")
  end

  @tag :feature
  test "a scope that matches nothing raises", %{session: session} do
    assert_raise RuntimeError, ~r/no element matched scope/, fn ->
      audit(session, scope: "#does-not-exist")
    end
  end

  @tag :feature
  test "a violation names the element by id", %{session: session} do
    render_fixture(session, ~s|<div id="wide" style="width:500px;height:10px"></div>|)
    v = session |> audit(scope: "#mlx") |> Enum.find(&(&1.check == :escapes_viewport))
    assert v.selector == "#wide"
    assert v.detail =~ "vw=320"
  end

  @tag :feature
  test "a selector drops database ids and LiveView's random ids", %{session: session} do
    render_fixture(
      session,
      ~s|<div id="row-3f2a9c1e-1111-4222-8333-444455556666-7" style="width:500px;height:10px"></div>| <>
        ~s|<div id="phx-GONVabc123XYZ"><p style="width:500px;height:10px"></p></div>|
    )

    selectors =
      session
      |> audit(scope: "#mlx")
      |> Enum.filter(&(&1.check == :escapes_viewport))
      |> Enum.map(& &1.selector)

    assert selectors == ["#row-*-*", "#phx-* p"]
  end

  @tag :feature
  test "escapes_viewport names only the outermost escaping element", %{session: session} do
    render_fixture(
      session,
      ~s|<div id="outer" style="width:500px"><div style="width:480px;height:10px"><span style="display:block;width:400px">x</span></div></div>|
    )

    escapes = session |> audit(scope: "#mlx") |> Enum.filter(&(&1.check == :escapes_viewport))
    assert Enum.map(escapes, & &1.selector) == ["#outer"]
  end

  @tag :feature
  test "clipped_text names the box doing the cutting, not every clipping ancestor",
       %{session: session} do
    render_fixture(
      session,
      ~s|<div id="outer" style="overflow:hidden;width:200px"><div id="inner" style="overflow:hidden;white-space:nowrap;width:60px">A considerably long fictional label</div></div>|
    )

    clipped = session |> audit(scope: "#mlx") |> Enum.filter(&(&1.check == :clipped_text))
    assert Enum.map(clipped, & &1.selector) == ["#inner"]
  end
end
