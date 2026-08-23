defmodule Mydia.Library.HdrTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.Hdr

  # Each row is {struct fields, expected tokens, expected display}.
  # A format that carries a compatible base emits that base as a second
  # token, so an operator who listed only "hdr10" still matches an HDR10+
  # or DV 8.1 file. Both decode as HDR10 on an HDR10 client.
  #
  # Bound at module level (rather than inside the describe block below) so it
  # can also be reused by the profile_format_strings/0 coverage test further
  # down without depending on describe-block attribute ordering.
  @cases [
    {%{base: nil, dv_profile: nil, bl_compat_id: nil}, [], nil},
    {%{base: :hdr10, dv_profile: nil, bl_compat_id: nil}, ["hdr10"], "HDR10"},
    {%{base: :hdr10_plus, dv_profile: nil, bl_compat_id: nil}, ["hdr10+", "hdr10"], "HDR10+"},
    {%{base: :hlg, dv_profile: nil, bl_compat_id: nil}, ["hlg"], "HLG"},
    {%{base: :hdr10, dv_profile: 8, bl_compat_id: 1}, ["dolby_vision", "hdr10"], "Dolby Vision"},
    {%{base: :hlg, dv_profile: 8, bl_compat_id: 4}, ["dolby_vision", "hlg"], "Dolby Vision"},
    {%{base: nil, dv_profile: 5, bl_compat_id: 0}, ["dolby_vision"], "Dolby Vision"},
    {%{base: :hdr10, dv_profile: 7, bl_compat_id: nil}, ["dolby_vision", "hdr10"], "Dolby Vision"}
  ]

  describe "profile_tokens/1 and display/1" do
    for {fields, tokens, display} <- @cases do
      test "#{inspect(fields)} derives #{inspect(tokens)} / #{inspect(display)}" do
        hdr = struct(Hdr, unquote(Macro.escape(fields)))
        assert Hdr.profile_tokens(hdr) == unquote(tokens)
        assert Hdr.display(hdr) == unquote(display)
      end
    end
  end

  describe "sdr?/1" do
    test "a Dolby Vision profile 5 file is not SDR even though its base is nil" do
      # This is the nil-test trap: hdr_format is nil by design for P5 because
      # it has no HDR10-compatible base layer.
      hdr = %Hdr{base: nil, dv_profile: 5, bl_compat_id: 0}
      refute Hdr.sdr?(hdr)
    end

    test "a file with no HDR signal at all is SDR" do
      assert Hdr.sdr?(%Hdr{})
    end
  end

  describe "profile_format_strings/0" do
    test "covers every token profile_tokens/1 can emit" do
      emitted =
        @cases
        |> Enum.flat_map(fn {fields, _tokens, _display} ->
          Hdr.profile_tokens(struct(Hdr, fields))
        end)
        |> Enum.uniq()

      assert emitted -- Hdr.profile_format_strings() == []
    end
  end

  describe "from_ffprobe/2" do
    defp dovi(profile, bl_compat_id) do
      %{
        "side_data_type" => "DOVI configuration record",
        "dv_profile" => profile,
        "dv_bl_signal_compatibility_id" => bl_compat_id
      }
    end

    test "smpte2084 is HDR10" do
      stream = %{"color_transfer" => "smpte2084"}
      assert %Hdr{base: :hdr10, dv_profile: nil} = Hdr.from_ffprobe(stream)
    end

    test "arib-std-b67 is HLG, not HDR10" do
      # REGRESSION: file_analyzer.ex:589 tested
      # `color_transfer in ["smpte2084", "arib-std-b67"]` and returned "HDR10",
      # making the HLG clause on the following line unreachable. Every HLG file
      # in every Mydia library was labeled HDR10.
      stream = %{"color_transfer" => "arib-std-b67"}
      assert %Hdr{base: :hlg} = Hdr.from_ffprobe(stream)
    end

    test "bt2020 primaries without a PQ or HLG transfer is SDR" do
      # REGRESSION: file_analyzer.ex:597 returned "HDR" for wide gamut alone.
      # Wide gamut without an HDR transfer function is SDR with a wide gamut.
      stream = %{"color_primaries" => "bt2020", "color_space" => "bt2020nc"}
      assert %Hdr{base: nil, dv_profile: nil} = Hdr.from_ffprobe(stream)
    end

    test "DV profile 8 with bl_compat_id 1 has an HDR10 base" do
      stream = %{"color_transfer" => "smpte2084", "side_data_list" => [dovi(8, 1)]}
      assert %Hdr{base: :hdr10, dv_profile: 8, bl_compat_id: 1} = Hdr.from_ffprobe(stream)
    end

    test "DV profile 8 with bl_compat_id 4 has an HLG base" do
      stream = %{"color_transfer" => "arib-std-b67", "side_data_list" => [dovi(8, 4)]}
      assert %Hdr{base: :hlg, dv_profile: 8, bl_compat_id: 4} = Hdr.from_ffprobe(stream)
    end

    test "DV profile 5 has no base even though it signals smpte2084" do
      # P5 files typically signal smpte2084 despite an IPTPQc2 base layer that
      # an HDR10 decoder cannot use. Trusting the transfer function alone would
      # mislabel every P5 file as HDR10.
      stream = %{"color_transfer" => "smpte2084", "side_data_list" => [dovi(5, 0)]}
      assert %Hdr{base: nil, dv_profile: 5, bl_compat_id: 0} = Hdr.from_ffprobe(stream)
    end

    test "DV profile 5 has no base even when bl_compat_id claims HDR10 compatibility" do
      # Guards clause ORDER in dv_base/3. The profile-5 clause must win over the
      # bl_compat_id clauses. With them reordered this returns :hdr10, which would
      # mislabel every profile 5 file. The dovi(5, 0) test above cannot catch that,
      # because the bl_compat_id 0 clause returns nil for any profile on its own.
      stream = %{"color_transfer" => "smpte2084", "side_data_list" => [dovi(5, 1)]}
      assert %Hdr{base: nil, dv_profile: 5, bl_compat_id: 1} = Hdr.from_ffprobe(stream)
    end

    test "DV profile 7 without a compatibility id falls back to the transfer function" do
      stream = %{
        "color_transfer" => "smpte2084",
        "side_data_list" => [
          %{"side_data_type" => "DOVI configuration record", "dv_profile" => 7}
        ]
      }

      assert %Hdr{base: :hdr10, dv_profile: 7, bl_compat_id: nil} = Hdr.from_ffprobe(stream)
    end

    test "bl_compat_id 2 (deprecated SDR-compatible) yields no base" do
      stream = %{"color_transfer" => "smpte2084", "side_data_list" => [dovi(8, 2)]}
      assert %Hdr{base: nil, dv_profile: 8, bl_compat_id: 2} = Hdr.from_ffprobe(stream)
    end

    test "frame side data promotes HDR10 to HDR10+" do
      stream = %{"color_transfer" => "smpte2084"}

      frames = [
        %{"side_data_type" => "HDR Dynamic Metadata SMPTE2094-40 (HDR10+)"}
      ]

      assert %Hdr{base: :hdr10_plus} = Hdr.from_ffprobe(stream, frames)
    end

    test "a Dolby Vision file is never promoted to HDR10+" do
      stream = %{"color_transfer" => "smpte2084", "side_data_list" => [dovi(8, 1)]}
      frames = [%{"side_data_type" => "HDR Dynamic Metadata SMPTE2094-40 (HDR10+)"}]
      assert %Hdr{base: :hdr10, dv_profile: 8} = Hdr.from_ffprobe(stream, frames)
    end

    test "a non-map stream yields an empty struct rather than raising" do
      assert Hdr.from_ffprobe(nil) == %Hdr{}
    end
  end

  describe "hdr10_plus?/1" do
    test "matches label variants case-insensitively" do
      # The exact label varies across ffmpeg builds. Pinning one literal string
      # is how the previous check broke: it tested for "HDR10+" while ffmpeg
      # emits "HDR Dynamic Metadata SMPTE2094-40 (HDR10+)".
      for label <- [
            "HDR Dynamic Metadata SMPTE2094-40 (HDR10+)",
            "HDR10+",
            "hdr dynamic metadata smpte2094-40"
          ] do
        assert Hdr.hdr10_plus?([%{"side_data_type" => label}]), "expected #{label} to match"
      end
    end

    test "does not match unrelated side data" do
      refute Hdr.hdr10_plus?([%{"side_data_type" => "Mastering display metadata"}])
      refute Hdr.hdr10_plus?([])
      refute Hdr.hdr10_plus?(nil)
    end
  end

  describe "needs_frame_probe?/1" do
    test "true only for a plain HDR10 result" do
      assert Hdr.needs_frame_probe?(%Hdr{base: :hdr10})
      refute Hdr.needs_frame_probe?(%Hdr{base: :hdr10, dv_profile: 8})
      refute Hdr.needs_frame_probe?(%Hdr{base: :hlg})
      refute Hdr.needs_frame_probe?(%Hdr{})
    end
  end

  describe "from_release_token/1" do
    test "recognises Dolby Vision spellings" do
      for token <- ["DV", "dv", "DoVi", "DolbyVision", "Dolby Vision", "dolby-vision"] do
        assert Hdr.from_release_token(token) == :dolby_vision, "failed on #{token}"
      end
    end

    test "recognises HDR10+ spellings" do
      for token <- ["HDR10+", "hdr10plus", "HDR10-Plus", "hdr10 plus"] do
        assert Hdr.from_release_token(token) == {:base, :hdr10_plus}, "failed on #{token}"
      end
    end

    test "recognises HDR10 and bare HDR" do
      assert Hdr.from_release_token("HDR10") == {:base, :hdr10}
      assert Hdr.from_release_token("HDR") == {:base, :hdr10}
    end

    test "recognises HLG" do
      assert Hdr.from_release_token("HLG") == {:base, :hlg}
    end

    test "returns :unknown for anything else" do
      assert Hdr.from_release_token("BluRay") == :unknown
      assert Hdr.from_release_token("") == :unknown
    end

    test "strips dots and underscores, which release names use heavily" do
      # Task 7 feeds this function tokens captured straight out of dot-separated
      # release names, so "Dolby.Vision" arrives with the dot intact. The old
      # parser this replaces handled that case explicitly.
      assert Hdr.from_release_token("Dolby.Vision") == :dolby_vision
      assert Hdr.from_release_token("Dolby_Vision") == :dolby_vision
      assert Hdr.from_release_token("HDR10_PLUS") == {:base, :hdr10_plus}
      assert Hdr.from_release_token("HDR10.Plus") == {:base, :hdr10_plus}
    end

    test "returns :unknown for non-binary input rather than raising" do
      assert Hdr.from_release_token(nil) == :unknown
      assert Hdr.from_release_token(123) == :unknown
    end
  end
end
