defmodule Mydia.Subtitles.Offset do
  @moduledoc """
  Shifts every cue in a subtitle body by a fixed number of milliseconds.

  Pure: no database, no processes, no ffmpeg. It runs *after*
  `Mydia.Subtitles.Format.convert/3`, on the format actually being delivered,
  so it only ever sees output Mydia produced with normalized line endings and a
  known shape rather than arbitrary provider bytes.

  Only the timing portion of a cue is rewritten. Cue text routinely contains
  timestamp-shaped substrings (a subtitle that quotes a clock, a converted file
  carrying a comment), and rewriting those would corrupt the text while looking
  like it worked. `Mydia.Subtitles.Format.rewrite_timing_line/1` scopes its own
  rewrite the same way and for the same reason. For SRT and VTT the timing sits
  on its own line, so the rewrite is scoped per line. ASS packs the free-text
  field onto the same physical line as the timestamps, so the rewrite there is
  scoped to the Start/End fields specifically.

  A cue pushed before zero has its start clamped to zero. A cue whose *end*
  also lands before zero is dropped entirely: it describes a moment that no
  longer exists in the timeline.
  """

  # SRT: 00:01:23,456   VTT: 00:01:23.456 or 01:23.456 (hours optional)
  @srt_time ~r/(\d{2}):(\d{2}):(\d{2}),(\d{3})/
  @vtt_time ~r/(?:(\d+):)?(\d{2}):(\d{2})\.(\d{3})/
  # ASS: 0:01:23.45, single-digit hours and centiseconds
  @ass_time ~r/(\d+):(\d{2}):(\d{2})\.(\d{2})/

  # ASS event lines (Dialogue:/Comment:) always carry these ten
  # comma-separated fields, in this order, per the SSA/ASS v4+ spec:
  # Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text.
  @ass_event_fields 10

  @doc """
  Returns `content` with every cue moved by `offset_ms`.

  A zero offset returns the input unchanged without parsing it, which keeps the
  common case free. An unrecognized format also returns the input unchanged
  rather than guessing at its timing syntax.
  """
  @spec shift(binary(), String.t(), integer()) :: binary()
  def shift(content, format, offset_ms)

  def shift(content, _format, 0), do: content

  def shift(content, "srt", offset_ms), do: shift_srt(content, offset_ms)
  def shift(content, "vtt", offset_ms), do: shift_vtt(content, offset_ms)
  def shift(content, "ass", offset_ms), do: shift_ass(content, offset_ms)
  def shift(content, _format, _offset_ms), do: content

  ## SRT

  defp shift_srt(content, offset_ms) do
    content
    |> String.trim_trailing()
    |> String.split(~r/\r?\n\r?\n/, trim: true)
    |> Enum.map(&shift_srt_block(&1, offset_ms))
    |> Enum.reject(&is_nil/1)
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", &format_srt_block/1)
    |> Kernel.<>("\n")
  end

  defp format_srt_block({{timing, ""}, index}), do: "#{index}\n#{timing}"
  defp format_srt_block({{timing, text}, index}), do: "#{index}\n#{timing}\n#{text}"

  # Returns {timing_line, text} or nil when the whole cue falls off the front
  # of the timeline. The leading cue number is discarded here because the
  # caller renumbers: dropping a cue must happen before that renumbering, or
  # it leaves a gap in the sequence.
  defp shift_srt_block(block, offset_ms) do
    lines = block |> String.trim() |> String.split(~r/\r?\n/)

    case Enum.find_index(lines, &String.contains?(&1, "-->")) do
      nil ->
        nil

      timing_index ->
        timing = Enum.at(lines, timing_index)
        text = lines |> Enum.drop(timing_index + 1) |> Enum.join("\n")

        case shift_timing_line(timing, offset_ms, @srt_time, &format_srt_time/1, &parse_hms/1) do
          :drop -> nil
          shifted -> {shifted, text}
        end
    end
  end

  ## VTT

  defp shift_vtt(content, offset_ms) do
    content
    |> String.trim_trailing()
    |> String.split(~r/\r?\n{2,}/, trim: true)
    |> Enum.map(&shift_vtt_block(&1, offset_ms))
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  # Blocks with no timing line are metadata (the WEBVTT header, NOTE, STYLE,
  # REGION) and pass through untouched. A cue block whose timing drops
  # entirely (its end also lands before zero) is dropped whole, cue
  # identifier and text included: nothing is left to time it.
  #
  # The timing line is located structurally, the same way SRT does it: the
  # first line containing "-->" is the timing line, full stop. A VTT cue may
  # carry an identifier line above it, and cue text below it may itself
  # contain an arrow or a timestamp-shaped substring; testing every line
  # independently (as an earlier version of this function did) would rewrite
  # or even drop a cue over text that merely looks like a timing line.
  defp shift_vtt_block(block, offset_ms) do
    lines = String.split(block, ~r/\r?\n/)

    case Enum.find_index(lines, &String.contains?(&1, "-->")) do
      nil -> block
      timing_index -> shift_vtt_lines(lines, timing_index, offset_ms)
    end
  end

  defp shift_vtt_lines(lines, timing_index, offset_ms) do
    timing = Enum.at(lines, timing_index)

    case shift_timing_line(timing, offset_ms, @vtt_time, &format_vtt_time/1, &parse_vtt_hms/1) do
      :drop ->
        nil

      shifted ->
        lines
        |> List.replace_at(timing_index, shifted)
        |> Enum.join("\n")
    end
  end

  ## ASS

  defp shift_ass(content, offset_ms) do
    content
    |> String.split(~r/\r?\n/)
    |> Enum.map(&shift_ass_line(&1, offset_ms))
    |> Enum.reject(&(&1 == :drop))
    |> Enum.join("\n")
  end

  defp shift_ass_line(line, offset_ms) do
    if String.starts_with?(line, "Dialogue:") or String.starts_with?(line, "Comment:") do
      shift_ass_event(line, offset_ms)
    else
      line
    end
  end

  # Splits into exactly @ass_event_fields fields so the free-text field keeps
  # any commas it contains, then rewrites only the Start and End fields. This
  # keeps the free text untouched even when it contains a timestamp-shaped
  # substring, the same guarantee SRT and VTT get from the timing living on
  # its own line.
  defp shift_ass_event(line, offset_ms) do
    case String.split(line, ",", parts: @ass_event_fields) do
      [layer, start_field, end_field | tail] ->
        shift_ass_fields(line, layer, start_field, end_field, tail, offset_ms)

      _ ->
        line
    end
  end

  defp shift_ass_fields(line, layer, start_field, end_field, tail, offset_ms) do
    with {:ok, start_ms} <- parse_ass_field(start_field),
         {:ok, end_ms} <- parse_ass_field(end_field) do
      new_end = end_ms + offset_ms

      if new_end <= 0 do
        :drop
      else
        new_start = start_ms + offset_ms

        Enum.join(
          [layer, format_ass_time(max(new_start, 0)), format_ass_time(max(new_end, 0)) | tail],
          ","
        )
      end
    else
      :error -> line
    end
  end

  defp parse_ass_field(field) do
    case Regex.run(@ass_time, field) do
      nil -> :error
      match -> {:ok, parse_ass_hms(match)}
    end
  end

  ## Shared

  # Rewrites every timestamp on one timing line. Returns `:drop` when the
  # last timestamp on the line (the cue's end) lands at or below zero after
  # the offset, since there is then nothing left of the cue to show.
  defp shift_timing_line(line, offset_ms, regex, formatter, parser) do
    times = regex |> Regex.scan(line) |> Enum.map(&(parser.(&1) + offset_ms))

    if times != [] and List.last(times) <= 0 do
      :drop
    else
      replace_times(line, regex, times, formatter)
    end
  end

  # `Regex.split/3` with `include_captures: true` alternates non-matching
  # text with whole matches: ["before", match1, "between", match2, "after"].
  # Matches always land at odd indices, so the corresponding shifted time can
  # be pulled off `times` by position without re-testing each fragment
  # against the regex.
  defp replace_times(line, regex, times, formatter) do
    regex
    |> Regex.split(line, include_captures: true, trim: false)
    |> Enum.with_index()
    |> Enum.map_join("", fn
      {_match, index} when rem(index, 2) == 1 -> next_time(times, index, formatter)
      {part, _index} -> part
    end)
  end

  defp next_time(times, index, formatter) do
    time = Enum.at(times, div(index, 2))
    formatter.(max(time, 0))
  end

  defp parse_hms([_full, h, m, s, ms]), do: to_ms(h, m, s) + String.to_integer(ms)

  defp parse_vtt_hms([_full, h, m, s, ms]) do
    hours = if h == "", do: 0, else: String.to_integer(h)

    hours * 3_600_000 + String.to_integer(m) * 60_000 + String.to_integer(s) * 1_000 +
      String.to_integer(ms)
  end

  defp parse_ass_hms([_full, h, m, s, cs]), do: to_ms(h, m, s) + String.to_integer(cs) * 10

  defp to_ms(h, m, s) do
    String.to_integer(h) * 3_600_000 + String.to_integer(m) * 60_000 +
      String.to_integer(s) * 1_000
  end

  defp format_srt_time(ms) do
    {h, m, s, milli} = break_down(ms)
    :io_lib.format("~2..0B:~2..0B:~2..0B,~3..0B", [h, m, s, milli]) |> IO.iodata_to_binary()
  end

  defp format_vtt_time(ms) do
    {h, m, s, milli} = break_down(ms)
    :io_lib.format("~2..0B:~2..0B:~2..0B.~3..0B", [h, m, s, milli]) |> IO.iodata_to_binary()
  end

  defp format_ass_time(ms) do
    {h, m, s, milli} = break_down(ms)
    :io_lib.format("~B:~2..0B:~2..0B.~2..0B", [h, m, s, div(milli, 10)]) |> IO.iodata_to_binary()
  end

  defp break_down(ms) do
    ms = max(ms, 0)

    {div(ms, 3_600_000), div(rem(ms, 3_600_000), 60_000), div(rem(ms, 60_000), 1_000),
     rem(ms, 1_000)}
  end
end
