defmodule Mydia.PgsFixture do
  @moduledoc """
  A PGS (Blu-ray bitmap) subtitle stream built byte by byte, and an MKV
  carrying it.

  ffmpeg copies and decodes PGS but cannot encode it from text, and a track
  cut from a real disc would put someone's dialogue in the repo. So this
  writes a stream ffmpeg's `pgssub` decoder reads as one bitmap: a display
  set showing a solid box at `show_at`, and one clearing it at `hide_at`.

  Each segment is a 13-byte header ("PG", PTS and DTS in 90 kHz ticks, the
  segment type, the payload size) followed by its payload.
  """

  import Bitwise

  @pds 0x14
  @ods 0x15
  @pcs 0x16
  @wds 0x17
  @end_of_display 0x80

  @doc "The raw `.sup` bytes."
  @spec sup(keyword()) :: binary()
  def sup(opts \\ []) do
    width = Keyword.get(opts, :width, 320)
    height = Keyword.get(opts, :height, 240)
    show = ticks(Keyword.get(opts, :show_at, 1.0))
    hide = ticks(Keyword.get(opts, :hide_at, 3.0))
    {box_w, box_h, box_x, box_y} = {100, 20, 110, 200}

    window = <<0, box_x::16, box_y::16, box_w::16, box_h::16>>

    IO.iodata_to_binary([
      # Epoch start, palette 0, one object (id 0) in window 0 at the box.
      segment(
        show,
        @pcs,
        <<width::16, height::16, 0x10, 0::16, 0x80, 0, 0, 1, 0::16, 0, 0, box_x::16, box_y::16>>
      ),
      segment(show, @wds, <<1>> <> window),
      # Palette 0, entry 1: white (Y=235, Cr=128, Cb=128), opaque.
      segment(show, @pds, <<0, 0, 1, 235, 128, 128, 255>>),
      segment(show, @ods, object(box_w, box_h)),
      segment(show, @end_of_display, <<>>),
      # A normal-state composition with no objects clears the screen.
      segment(hide, @pcs, <<width::16, height::16, 0x10, 1::16, 0x00, 0, 0, 0>>),
      segment(hide, @wds, <<1>> <> window),
      segment(hide, @end_of_display, <<>>)
    ])
  end

  @doc """
  Writes an MKV to `path`: 5 s of black 320x240 video as stream 0 and the
  PGS track as stream 1. Forces the Matroska muxer, since fixture paths end
  in `.mp4` and MP4 cannot carry PGS. Needs ffmpeg with libx264 on PATH.
  """
  @spec write_mkv!(String.t()) :: :ok
  def write_mkv!(path) do
    sup_path = path <> ".sup"
    File.write!(sup_path, sup())

    {_output, 0} =
      System.cmd(
        "ffmpeg",
        [
          "-v",
          "error",
          "-y",
          "-f",
          "lavfi",
          "-i",
          "color=c=black:s=320x240:r=24:d=5",
          "-i",
          sup_path,
          "-map",
          "0:v",
          "-map",
          "1:s",
          "-c:v",
          "libx264",
          "-preset",
          "ultrafast",
          "-c:s",
          "copy",
          "-f",
          "matroska",
          path
        ],
        stderr_to_stdout: true
      )

    File.rm!(sup_path)
    :ok
  end

  defp ticks(seconds), do: round(seconds * 90_000)

  defp segment(pts, type, data),
    do: <<"PG", pts::32, 0::32, type, byte_size(data)::16, data::binary>>

  # Object 0, version 0, first and last fragment, then the RLE bitmap. Each
  # line is one run of `w` pixels of palette entry 1, then end-of-line.
  defp object(w, h) do
    line = <<0, 0xC0 ||| w >>> 8, w &&& 0xFF, 1, 0, 0>>
    data = <<w::16, h::16, :binary.copy(line, h)::binary>>
    <<0::16, 0, 0xC0, byte_size(data)::24, data::binary>>
  end
end
