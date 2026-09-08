defmodule Mydia.Streaming.HardwareAccelTest do
  use ExUnit.Case, async: false

  alias Mydia.Streaming.HardwareAccel
  alias Mydia.Streaming.HardwareAccel.Capabilities

  @vaapi %Capabilities{
    backend: :vaapi,
    device: "/dev/dri/renderD128",
    encoders: [:h264],
    decode_profiles: [:hevc, :av1]
  }

  defp start_with(caps, opts \\ []) do
    name = :"hwaccel_#{System.unique_integer([:positive])}"
    opts = Keyword.merge([name: name, probe: fn _ -> caps end, cap: 3], opts)
    start_supervised!({HardwareAccel, opts})
    name
  end

  describe "capabilities/0 without a running process" do
    test "reports software rather than crashing" do
      # Every existing streaming test runs with no probe process. They must keep
      # asserting software arguments, so absence is a supported state.
      caps = HardwareAccel.capabilities()

      assert caps.backend == :none
      assert caps.reason =~ "not running"
    end
  end

  describe "capabilities/1" do
    test "returns what the probe found" do
      name = start_with(@vaapi)

      assert HardwareAccel.capabilities(name).backend == :vaapi
    end
  end

  describe "leases" do
    test "playback takes slots up to the cap" do
      name = start_with(@vaapi, cap: 2)

      assert {:ok, _} = HardwareAccel.lease(name, :playback)
      assert {:ok, _} = HardwareAccel.lease(name, :playback)
      assert :refused = HardwareAccel.lease(name, :playback)
    end

    test "background is refused one slot early so playback keeps headroom" do
      name = start_with(@vaapi, cap: 2)

      assert {:ok, _} = HardwareAccel.lease(name, :background)
      assert :refused = HardwareAccel.lease(name, :background)
      assert {:ok, _} = HardwareAccel.lease(name, :playback)
    end

    test "a cap of one refuses background entirely" do
      name = start_with(@vaapi, cap: 1)

      assert :refused = HardwareAccel.lease(name, :background)
      assert {:ok, _} = HardwareAccel.lease(name, :playback)
    end

    test "releasing frees the slot" do
      name = start_with(@vaapi, cap: 1)

      {:ok, ref} = HardwareAccel.lease(name, :playback)
      assert :refused = HardwareAccel.lease(name, :playback)

      :ok = HardwareAccel.release(name, ref)
      assert {:ok, _} = HardwareAccel.lease(name, :playback)
    end

    test "software capabilities refuse every lease" do
      name = start_with(Capabilities.software("no device"))

      assert :refused = HardwareAccel.lease(name, :playback)
    end
  end

  describe "report_failure/3" do
    test "demotes only the failing codec, keeping the rest on full hardware" do
      # A device whose AV1 decode is advertised but broken must not lose HEVC,
      # which is 94.5% of the library.
      name = start_with(@vaapi, demote_after: 2)

      HardwareAccel.report_failure(name, :vaapi, "av1")
      assert Capabilities.can_decode?(HardwareAccel.capabilities(name), :av1)

      HardwareAccel.report_failure(name, :vaapi, "av1")
      caps = HardwareAccel.capabilities(name)

      refute Capabilities.can_decode?(caps, :av1)
      assert Capabilities.can_decode?(caps, :hevc)
      assert caps.backend == :vaapi
    end

    test "an unknown codec name never demotes anything" do
      name = start_with(@vaapi, demote_after: 1)

      HardwareAccel.report_failure(name, :vaapi, "not_a_codec")

      assert HardwareAccel.capabilities(name).decode_profiles == [:hevc, :av1]
    end
  end

  test "the supervisor does not start the probe under mix test" do
    # If this fails, every streaming test that asserts software arguments is
    # now at the mercy of whether the developer's machine has a GPU.
    assert GenServer.whereis(Mydia.Streaming.HardwareAccel) == nil
  end
end
