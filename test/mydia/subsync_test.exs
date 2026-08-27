defmodule Mydia.SubsyncTest do
  use ExUnit.Case, async: true

  alias Mydia.Subsync

  defp evenly_spaced(count), do: for(i <- 0..(count - 1), do: {i * 7000, i * 7000 + 2000})

  defp shifted(spans, by), do: Enum.map(spans, fn {s, e} -> {s + by, e + by} end)

  describe "align/2" do
    test "recovers an exact constant shift across the NIF boundary" do
      reference = evenly_spaced(40)
      late = shifted(reference, 2500)

      assert {-2500, score} = Subsync.align(reference, late)
      assert score / length(late) > 0.9
    end

    test "returns a zero offset for an already synced track" do
      reference = evenly_spaced(40)

      assert {0, score} = Subsync.align(reference, reference)
      assert score / length(reference) > 0.9
    end

    test "returns a zero score for empty input" do
      assert {0, +0.0} = Subsync.align([], evenly_spaced(4))
      assert {0, +0.0} = Subsync.align(evenly_spaced(4), [])
    end
  end

  describe "voice_spans/1" do
    @tag :tmp_dir
    test "returns no spans for digital silence", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "silence.pcm")
      File.write!(path, :binary.copy(<<0, 0>>, 8000))

      assert {:ok, []} = Subsync.voice_spans(path)
    end

    test "returns an error for a missing file" do
      assert {:error, message} = Subsync.voice_spans("/nonexistent/audio.pcm")
      assert message =~ "cannot open"
    end
  end
end
