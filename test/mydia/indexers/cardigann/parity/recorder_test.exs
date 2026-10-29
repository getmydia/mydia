defmodule Mydia.Indexers.Cardigann.Parity.RecorderTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.Parity.Capture.Exchange
  alias Mydia.Indexers.Cardigann.Parity.{Capture, Recorder, RequestKey}

  defp key(path), do: RequestKey.new("GET", "https://harbor.invalid/#{path}", nil)

  test "keeps exchanges in order and redacts credential headers" do
    {:ok, rec} = Recorder.start_link()

    ok = %{
      status: 200,
      headers: [
        %{name: "content-type", value: "text/html"},
        %{name: "set-cookie", value: "sid=s3cret"}
      ],
      body: "one"
    }

    Recorder.record(rec, key("a"), {:ok, ok})
    Recorder.record(rec, key("b"), {:ok, %{ok | body: "two"}})

    assert [%Exchange{body: "one"} = first, %Exchange{body: "two"}] = Recorder.exchanges(rec)
    assert first.request == key("a")
    assert first.status == 200
    assert {"content-type", "text/html"} in first.headers
    assert {"set-cookie", "<redacted>"} in first.headers
    refute inspect(first) =~ "s3cret"
  end

  test "records an error kind without a status" do
    {:ok, rec} = Recorder.start_link()
    Recorder.record(rec, key("a"), {:error, {:timeout, "slow"}})
    Recorder.record(rec, key("b"), {:error, {:connect, "refused"}})

    assert [%Exchange{error: :timeout, status: nil}, %Exchange{error: :connect}] =
             Recorder.exchanges(rec)
  end

  @tag :tmp_dir
  test "every host error kind survives write! and read!", %{tmp_dir: dir} do
    {:ok, rec} = Recorder.start_link()
    kinds = [:timeout, :connect, :blocked, :other]
    for k <- kinds, do: Recorder.record(rec, key("#{k}"), {:error, {k, "x"}})

    capture = %Capture{
      definition: "harbor",
      ref: "t",
      query: %{kind: :generic, term: "x"},
      exchanges: Recorder.exchanges(rec)
    }

    Capture.write!(capture, dir)
    assert dir |> Capture.read!() |> Map.fetch!(:exchanges) |> Enum.map(& &1.error) == kinds
  end
end
