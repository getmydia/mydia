defmodule MydiaWeb.Features.GeometrySelfTest do
  @moduledoc """
  Tests the geometry assertions themselves against markup with known
  overlap, so a failure here means the helper is broken rather than the UI.
  """

  use MydiaWeb.FeatureCase, async: false

  @moduletag :feature

  describe "refute_covered/2" do
    @tag :feature
    test "passes for an unobstructed element", %{session: session} do
      login_as_admin(session)

      session
      |> visit("/")
      |> wait_for_liveview()

      inject(session, """
        var el = document.createElement('div');
        el.id = 'geo-clear';
        el.style.cssText =
          'position:fixed;top:10px;left:10px;width:100px;height:100px;z-index:9999;background:red';
        document.body.appendChild(el);
      """)

      refute_covered(session, "#geo-clear")
    end

    @tag :feature
    test "fails and names the covering element", %{session: session} do
      login_as_admin(session)

      session
      |> visit("/")
      |> wait_for_liveview()

      inject(session, """
        var under = document.createElement('div');
        under.id = 'geo-under';
        under.style.cssText =
          'position:fixed;top:10px;left:10px;width:100px;height:100px;z-index:9998;background:blue';
        document.body.appendChild(under);

        var over = document.createElement('div');
        over.id = 'geo-over';
        over.style.cssText =
          'position:fixed;top:10px;left:10px;width:100px;height:100px;z-index:9999;background:green';
        document.body.appendChild(over);
      """)

      error =
        assert_raise ExUnit.AssertionError, fn ->
          refute_covered(session, "#geo-under")
        end

      assert error.message =~ "geo-over"
    end
  end

  describe "assert_in_viewport/2" do
    @tag :feature
    test "passes for an on-screen element and fails for an off-screen one",
         %{session: session} do
      login_as_admin(session)

      session
      |> visit("/")
      |> wait_for_liveview()

      inject(session, """
        var on = document.createElement('div');
        on.id = 'geo-onscreen';
        on.style.cssText =
          'position:fixed;top:10px;left:10px;width:50px;height:50px;z-index:9999';
        document.body.appendChild(on);

        var off = document.createElement('div');
        off.id = 'geo-offscreen';
        off.style.cssText =
          'position:fixed;top:-500px;left:10px;width:50px;height:50px;z-index:9999';
        document.body.appendChild(off);
      """)

      assert_in_viewport(session, "#geo-onscreen")

      assert_raise ExUnit.AssertionError, fn ->
        assert_in_viewport(session, "#geo-offscreen")
      end
    end
  end

  describe "refute_clipped/2" do
    @tag :feature
    test "passes for a contained child and fails for an overflowing one",
         %{session: session} do
      login_as_admin(session)

      session
      |> visit("/")
      |> wait_for_liveview()

      inject(session, """
        var box = document.createElement('div');
        box.id = 'geo-scroll';
        box.style.cssText =
          'position:fixed;top:100px;left:100px;width:200px;height:200px;' +
          'overflow:auto;z-index:9999;background:#eee';
        document.body.appendChild(box);

        var fits = document.createElement('div');
        fits.id = 'geo-fits';
        fits.style.cssText = 'width:50px;height:50px;background:teal';
        box.appendChild(fits);

        var overflows = document.createElement('div');
        overflows.id = 'geo-overflows';
        overflows.style.cssText =
          'position:absolute;top:0;left:0;width:600px;height:50px;background:orange';
        box.appendChild(overflows);
      """)

      refute_clipped(session, "#geo-fits")

      error =
        assert_raise ExUnit.AssertionError, fn ->
          refute_clipped(session, "#geo-overflows")
        end

      assert error.message =~ "geo-scroll"
    end
  end

  defp inject(session, script) do
    Wallaby.Browser.execute_script(session, script, [])
    session
  end
end
