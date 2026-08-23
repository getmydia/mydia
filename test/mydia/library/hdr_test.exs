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
end
