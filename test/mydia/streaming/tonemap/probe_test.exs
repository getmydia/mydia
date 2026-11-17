defmodule Mydia.Streaming.Tonemap.ProbeTest do
  use ExUnit.Case, async: true

  alias Mydia.Streaming.Tonemap
  alias Mydia.Streaming.Tonemap.Probe

  @listing """
   .. libplacebo        N->V       Apply various GPU filters from libplacebo
   .S tonemap           V->V       Conversion to/from different dynamic ranges.
   .. tonemap_vaapi     V->V       VAAPI VPP for tone-mapping
   .S zscale            V->V       Apply resizing, colorspace and bit depth conversion.
  """

  # Answers `-filters` with the listing, and every other invocation with
  # `test_result`. Reports each invocation to the test process.
  defp runner(listing, test_result) do
    parent = self()

    fn _exe, args, _timeout ->
      send(parent, {:ran, args})

      if "-filters" in args, do: {:ok, listing}, else: test_result
    end
  end

  describe "parse_filters/1" do
    test "finds all four filters in a real listing" do
      assert Probe.parse_filters(@listing) == %{
               zscale: true,
               tonemap: true,
               libplacebo: true,
               tonemap_vaapi: true
             }
    end

    test "reports none for empty output" do
      assert Probe.parse_filters("") == %{
               zscale: false,
               tonemap: false,
               libplacebo: false,
               tonemap_vaapi: false
             }
    end
  end

  describe "run/1" do
    test "a listed filter that fails its test run stays false" do
      result = Probe.run(vaapi?: true, runner: runner(@listing, {:error, {:exit, 1, "boom"}}))

      assert result == %Tonemap{zscale: true, libplacebo: false, vaapi: false}
    end

    test "everything listed and working gives all three" do
      result =
        Probe.run(
          vaapi?: true,
          device: "/dev/dri/renderD128",
          runner: runner(@listing, {:ok, ""})
        )

      assert result == %Tonemap{zscale: true, libplacebo: true, vaapi: true}
    end

    test "never runs the vaapi test when vaapi? is false" do
      result = Probe.run(vaapi?: false, runner: runner(@listing, {:ok, ""}))

      assert result == %Tonemap{zscale: true, libplacebo: true, vaapi: false}
      assert_all_args_free_of("tonemap_vaapi")
    end

    test "zscale needs both zscale and tonemap listed" do
      only_zscale = " .S zscale            V->V       Apply resizing.\n"

      assert %Tonemap{zscale: false} = Probe.run(runner: runner(only_zscale, {:ok, ""}))
    end

    test "an unavailable ffmpeg gives none" do
      assert Probe.run(runner: fn _, _, _ -> {:error, :not_found} end) == Tonemap.none()
    end
  end

  defp assert_all_args_free_of(fragment) do
    receive do
      {:ran, args} ->
        refute Enum.any?(args, &String.contains?(&1, fragment))
        assert_all_args_free_of(fragment)
    after
      0 -> :ok
    end
  end
end
