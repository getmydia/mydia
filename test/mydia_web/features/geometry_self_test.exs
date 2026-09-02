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

  describe "assert_same_height/4" do
    @tag :feature
    test "passes for two elements with equal height", %{session: session} do
      login_as_admin(session)

      session
      |> visit("/")
      |> wait_for_liveview()

      inject(session, """
        var a = document.createElement('div');
        a.id = 'geo-height-eq-a';
        a.style.cssText =
          'position:fixed;top:10px;left:10px;width:50px;height:200px;z-index:9999';
        document.body.appendChild(a);

        var b = document.createElement('div');
        b.id = 'geo-height-eq-b';
        b.style.cssText =
          'position:fixed;top:10px;left:200px;width:50px;height:200px;z-index:9999';
        document.body.appendChild(b);
      """)

      assert_same_height(session, "#geo-height-eq-a", "#geo-height-eq-b")
    end

    @tag :feature
    test "passes when the difference is within tolerance", %{session: session} do
      login_as_admin(session)

      session
      |> visit("/")
      |> wait_for_liveview()

      inject(session, """
        var a = document.createElement('div');
        a.id = 'geo-height-tol-a';
        a.style.cssText =
          'position:fixed;top:10px;left:10px;width:50px;height:200px;z-index:9999';
        document.body.appendChild(a);

        var b = document.createElement('div');
        b.id = 'geo-height-tol-b';
        b.style.cssText =
          'position:fixed;top:10px;left:200px;width:50px;height:200.5px;z-index:9999';
        document.body.appendChild(b);
      """)

      assert_same_height(session, "#geo-height-tol-a", "#geo-height-tol-b")
    end

    @tag :feature
    test "fails and names both selectors, both heights, and the delta when they differ",
         %{session: session} do
      login_as_admin(session)

      session
      |> visit("/")
      |> wait_for_liveview()

      inject(session, """
        var a = document.createElement('div');
        a.id = 'geo-height-diff-a';
        a.style.cssText =
          'position:fixed;top:10px;left:10px;width:50px;height:200px;z-index:9999';
        document.body.appendChild(a);

        var b = document.createElement('div');
        b.id = 'geo-height-diff-b';
        b.style.cssText =
          'position:fixed;top:10px;left:200px;width:50px;height:212px;z-index:9999';
        document.body.appendChild(b);
      """)

      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_same_height(session, "#geo-height-diff-a", "#geo-height-diff-b")
        end

      assert error.message =~ "geo-height-diff-a"
      assert error.message =~ "geo-height-diff-b"
      assert error.message =~ "200px"
      assert error.message =~ "212px"
      assert error.message =~ "delta 12px"
    end

    # A delta a hair over the tolerance must not be displayed as though it sat
    # exactly on it. Rounding the reported delta to 1 decimal place printed a
    # failing 1.04px as "delta 1px, tolerance 1px", which reads like a message
    # that should have passed and sends the reader hunting for a bug in the
    # assertion rather than in their layout.
    @tag :feature
    test "reports a just-over-tolerance delta without rounding it onto the boundary",
         %{session: session} do
      login_as_admin(session)

      session
      |> visit("/")
      |> wait_for_liveview()

      inject(session, """
        var a = document.createElement('div');
        a.id = 'geo-height-edge-a';
        a.style.cssText =
          'position:fixed;top:10px;left:10px;width:50px;height:200px;z-index:9999';
        document.body.appendChild(a);

        var b = document.createElement('div');
        b.id = 'geo-height-edge-b';
        b.style.cssText =
          'position:fixed;top:10px;left:200px;width:50px;height:201.04px;z-index:9999';
        document.body.appendChild(b);
      """)

      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_same_height(session, "#geo-height-edge-a", "#geo-height-edge-b")
        end

      # Matched as a pattern rather than an exact string: the browser snaps the
      # requested 201.04px to its own device-pixel grid (observed 201.03px), so
      # pinning the literal would make this test about Chrome's rounding rather
      # than about ours. What matters is that a sub-pixel delta survives into
      # the message instead of collapsing onto the tolerance.
      refute error.message =~ "delta 1px"
      assert error.message =~ ~r/delta 1\.\d+px/
    end

    @tag :feature
    test "fails with a distinct sentinel when the first selector matches nothing",
         %{session: session} do
      login_as_admin(session)

      session
      |> visit("/")
      |> wait_for_liveview()

      inject(session, """
        var b = document.createElement('div');
        b.id = 'geo-height-onlyb';
        b.style.cssText =
          'position:fixed;top:10px;left:200px;width:50px;height:200px;z-index:9999';
        document.body.appendChild(b);
      """)

      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_same_height(session, "#geo-height-missing-a", "#geo-height-onlyb")
        end

      assert error.message =~ "geo-height-missing-a"
    end

    @tag :feature
    test "fails with a distinct sentinel when the second selector matches nothing",
         %{session: session} do
      login_as_admin(session)

      session
      |> visit("/")
      |> wait_for_liveview()

      inject(session, """
        var a = document.createElement('div');
        a.id = 'geo-height-onlya';
        a.style.cssText =
          'position:fixed;top:10px;left:10px;width:50px;height:200px;z-index:9999';
        document.body.appendChild(a);
      """)

      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_same_height(session, "#geo-height-onlya", "#geo-height-missing-b")
        end

      assert error.message =~ "geo-height-missing-b"
    end

    @tag :feature
    test "fails with a distinct sentinel when the first element has zero height",
         %{session: session} do
      login_as_admin(session)

      session
      |> visit("/")
      |> wait_for_liveview()

      inject(session, """
        var a = document.createElement('div');
        a.id = 'geo-height-zero-a';
        a.style.cssText =
          'position:fixed;top:10px;left:10px;width:50px;height:0px;z-index:9999';
        document.body.appendChild(a);

        var b = document.createElement('div');
        b.id = 'geo-height-zero-b';
        b.style.cssText =
          'position:fixed;top:10px;left:200px;width:50px;height:200px;z-index:9999';
        document.body.appendChild(b);
      """)

      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_same_height(session, "#geo-height-zero-a", "#geo-height-zero-b")
        end

      assert error.message =~ "geo-height-zero-a"
    end

    @tag :feature
    test "fails with a distinct sentinel when the second element has zero height",
         %{session: session} do
      login_as_admin(session)

      session
      |> visit("/")
      |> wait_for_liveview()

      inject(session, """
        var a = document.createElement('div');
        a.id = 'geo-height-zerob-a';
        a.style.cssText =
          'position:fixed;top:10px;left:10px;width:50px;height:200px;z-index:9999';
        document.body.appendChild(a);

        var b = document.createElement('div');
        b.id = 'geo-height-zerob-b';
        b.style.cssText =
          'position:fixed;top:10px;left:200px;width:50px;height:0px;z-index:9999';
        document.body.appendChild(b);
      """)

      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_same_height(session, "#geo-height-zerob-a", "#geo-height-zerob-b")
        end

      assert error.message =~ "geo-height-zerob-b"
    end
  end

  defp inject(session, script) do
    Wallaby.Browser.execute_script(session, script, [])
    session
  end
end
