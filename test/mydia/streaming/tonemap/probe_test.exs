defmodule Mydia.Streaming.Tonemap.ProbeTest do
  use ExUnit.Case, async: true

  alias Mydia.Streaming.Tonemap
  alias Mydia.Streaming.Tonemap.Filters
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
      assert Probe.parse_filters(@listing) == %Filters{
               zscale: true,
               tonemap: true,
               libplacebo: true,
               tonemap_vaapi: true
             }
    end

    test "reports none for empty output" do
      assert Probe.parse_filters("") == %Filters{}
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

    test "the vaapi test runs on a generated clip that is removed afterwards" do
      result = Probe.run(vaapi?: true, runner: runner(@listing, {:ok, ""}))

      assert result.vaapi
      args = ran_args()
      gen = Enum.find(args, &("libx265" in &1))
      vaapi = Enum.find(args, &vaapi_vf?/1)

      clip = List.last(gen)
      assert String.ends_with?(clip, "hdr10.mkv")
      assert Enum.any?(gen, &String.contains?(&1, "master-display="))
      assert Enum.at(vaapi, Enum.find_index(vaapi, &(&1 == "-i")) + 1) == clip
      assert Enum.find_index(args, &(&1 == gen)) < Enum.find_index(args, &(&1 == vaapi))
      refute File.exists?(Path.dirname(clip))
    end

    test "a failed clip generation gives vaapi false and never runs the vaapi test" do
      runner = fn _exe, args, _timeout ->
        cond do
          "-filters" in args -> {:ok, @listing}
          "libx265" in args -> {:error, {:exit, 1, "Unknown encoder 'libx265'"}}
          true -> {:ok, ""}
        end
      end

      result = Probe.run(vaapi?: true, runner: wrap(runner))

      refute result.vaapi

      refute Enum.any?(
               ran_args(),
               &Enum.any?(&1, fn a -> String.contains?(a, "tonemap_vaapi") end)
             )
    end

    test "vaapi? false runs neither the clip generation nor the vaapi test" do
      Probe.run(vaapi?: false, runner: runner(@listing, {:ok, ""}))

      refute Enum.any?(ran_args(), &("libx265" in &1))
    end

    test "zscale needs both zscale and tonemap listed" do
      only_zscale = " .S zscale            V->V       Apply resizing.\n"

      assert %Tonemap{zscale: false} = Probe.run(runner: runner(only_zscale, {:ok, ""}))
    end

    test "an unavailable ffmpeg gives none" do
      assert Probe.run(runner: fn _, _, _ -> {:error, :not_found} end) == Tonemap.none()
    end
  end

  defp wrap(runner) do
    parent = self()

    fn exe, args, timeout ->
      send(parent, {:ran, args})
      runner.(exe, args, timeout)
    end
  end

  defp vaapi_vf?(args), do: Enum.any?(args, &String.contains?(&1, "tonemap_vaapi"))

  defp ran_args(acc \\ []) do
    receive do
      {:ran, args} -> ran_args([args | acc])
    after
      0 -> Enum.reverse(acc)
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
