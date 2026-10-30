defmodule MydiaWeb.Features.MobileLayoutSelfTest do
  @moduledoc """
  Tests the mobile layout checker itself against markup with a known defect
  and a known-good twin, so a failure here means the checker is broken rather
  than the UI. A checker that returns [] for everything fails the "fires"
  half of every case.
  """
  use MydiaWeb.FeatureCase, async: false

  @moduletag :feature

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
     ~s|<span style="font-size:12px">fine</span>|}
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
      checks = session |> audit(scope: "#mlx") |> Enum.map(& &1.check)
      refute unquote(check) in checks
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
end
