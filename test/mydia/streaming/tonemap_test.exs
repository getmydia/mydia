defmodule Mydia.Streaming.TonemapTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.Hdr
  alias Mydia.Streaming.Tonemap

  describe "can_tonemap?/2" do
    test "SDR is always true, there is nothing to do" do
      assert Tonemap.can_tonemap?(Tonemap.none(), %Hdr{})
    end

    test "HDR10 needs zscale or libplacebo" do
      hdr = %Hdr{base: :hdr10}
      assert Tonemap.can_tonemap?(%Tonemap{zscale: true}, hdr)
      assert Tonemap.can_tonemap?(%Tonemap{libplacebo: true}, hdr)
      refute Tonemap.can_tonemap?(Tonemap.none(), hdr)
      refute Tonemap.can_tonemap?(%Tonemap{vaapi: true}, hdr)
    end

    test "Dolby Vision profile 5 needs libplacebo" do
      hdr = %Hdr{dv_profile: 5}
      refute Tonemap.can_tonemap?(%Tonemap{zscale: true}, hdr)
      assert Tonemap.can_tonemap?(%Tonemap{libplacebo: true}, hdr)
    end

    test "Dolby Vision with an HDR10 base only needs zscale" do
      assert Tonemap.can_tonemap?(%Tonemap{zscale: true}, %Hdr{base: :hdr10, dv_profile: 8})
    end
  end

  test "none/0 has every capability off" do
    assert Tonemap.none() == %Tonemap{zscale: false, libplacebo: false, vaapi: false}
  end

  test "current/0 defaults to none/0 when nothing was stored" do
    assert Tonemap.current() == Tonemap.none()
  end
end
