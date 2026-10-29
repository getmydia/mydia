defmodule Mydia.Indexers.Cardigann.Parity.RatchetTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.Parity.{Divergence, Ratchet}
  alias Mydia.Indexers.Cardigann.Parity.Ratchet.Entry

  defp div(field \\ :size),
    do: %Divergence{
      definition: "lantern",
      query: :rss,
      kind: :field,
      field: field,
      native: 1234,
      wasm: 1200
    }

  defp entry(field \\ :size, reason \\ "rounding"),
    do: %Entry{definition: "lantern", query: :rss, kind: :field, field: field, reason: reason}

  defp tmp_file(contents) do
    path = Path.join(System.tmp_dir!(), "ratchet_#{System.unique_integer([:positive])}.exs")
    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "a listed divergence passes" do
    assert :ok = Ratchet.check([div()], [entry()])
  end

  test "an unlisted divergence is new" do
    assert {:error, %{new: [%Divergence{field: :size}], stale: [], todo: []}} =
             Ratchet.check([div()], [])
  end

  test "a listed entry with no divergence is stale" do
    assert {:error, %{new: [], stale: [%Entry{field: :size}], todo: []}} =
             Ratchet.check([], [entry()])
  end

  test "TODO reasons are reported" do
    assert {:error, %{todo: [%Entry{reason: "TODO"}]}} =
             Ratchet.check([div()], [entry(:size, "TODO")])
  end

  test "render keeps existing reasons, marks new ones TODO, and round-trips" do
    divs = [div(:title), div(:size)]
    source = Ratchet.render(divs, [entry(:size, "rounding")])
    {list, _} = Code.eval_string(source)

    assert [%{field: :size, reason: "rounding"}, %{field: :title, reason: "TODO"}] = list
    path = tmp_file(source)
    assert [%Entry{field: :size, kind: :field}, %Entry{field: :title}] = Ratchet.load!(path)
  end

  test "render writes what mix format would, long reasons included" do
    reason = String.duplicate("a reason long enough to wrap the line ", 4)
    source = Ratchet.render([div(:title)], [entry(:title, reason)])

    assert source == (source |> Code.format_string!() |> IO.iodata_to_binary()) <> "\n"
  end

  test "load! raises on a blank reason" do
    path =
      tmp_file(~s|[%{definition: "x", query: :rss, kind: :outcome, field: nil, reason: "  "}]|)

    assert_raise ArgumentError, fn -> Ratchet.load!(path) end
  end

  test "format_failure describes each group" do
    msg =
      Ratchet.format_failure(%{
        new: [div()],
        stale: [entry(:title)],
        todo: [entry(:seeders, "TODO")]
      })

    assert msg =~ "new divergence: lantern/rss field size, native 1234 vs wasm 1200"
    assert msg =~ "fixed, delete this entry: lantern/rss field title"
    assert msg =~ "annotate: lantern/rss field seeders"
  end

  test "keep_unrun keeps entries of definitions that were not part of the run" do
    other = %Entry{definition: "orchard", query: :rss, kind: :count, field: nil, reason: "kept"}
    existing = [entry(:size, "rounding"), other]

    merged = Ratchet.keep_unrun([div(:seeders)], existing, ["lantern"])
    source = Ratchet.render(merged, existing)

    assert source =~ ~s(definition: "orchard")
    assert source =~ ~s(reason: "kept")
    assert source =~ "field: :seeders"
    refute source =~ "field: :size"
  end
end
