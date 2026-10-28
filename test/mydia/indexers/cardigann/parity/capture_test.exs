defmodule Mydia.Indexers.Cardigann.Parity.CaptureTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.Parity.{Capture, RequestKey}
  alias Mydia.Indexers.Cardigann.Parity.Capture.Exchange

  @tag :tmp_dir
  test "write then read round-trips", %{tmp_dir: dir} do
    capture = %Capture{
      definition: "example",
      ref: "abc123",
      query: %{kind: :rss, term: ""},
      exchanges: [
        %Exchange{
          request: RequestKey.new(:get, "https://t.example/s?b=1&a=2", nil),
          status: 200,
          headers: [{"content-type", "text/html; charset=windows-1251"}],
          body: <<0xC0, 0xE1>>
        },
        %Exchange{
          request: RequestKey.new(:post, "https://t.example/s", <<0xFF, 0xFE>>),
          error: :timeout
        }
      ]
    }

    assert :ok = Capture.write!(capture, dir)
    assert File.read!(Path.join(dir, "001.html")) == <<0xC0, 0xE1>>
    refute File.exists?(Path.join(dir, "002.bin"))
    assert Enum.sort(File.ls!(dir)) == ["001.html", "exchanges.json"]
    assert Capture.read!(dir) == capture
  end

  @tag :tmp_dir
  test "redacted headers round-trip and leave no cookie value", %{tmp_dir: dir} do
    headers =
      Capture.redact_headers([
        {"Cookie", "session=s3cret"},
        {"set-cookie", "a=b"},
        {"Authorization", "Bearer t0ken"},
        {"content-type", "application/json"}
      ])

    assert headers == [
             {"Cookie", "<redacted>"},
             {"set-cookie", "<redacted>"},
             {"Authorization", "<redacted>"},
             {"content-type", "application/json"}
           ]

    capture = %Capture{
      definition: "example",
      ref: "r",
      query: %{kind: :generic, term: "Quiet Orchard"},
      exchanges: [
        %Exchange{
          request: RequestKey.new(:get, "https://t.example/", nil),
          status: 200,
          headers: headers,
          body: "{}"
        }
      ]
    }

    Capture.write!(capture, dir)
    json = File.read!(Path.join(dir, "exchanges.json"))
    refute json =~ "s3cret"
    assert File.exists?(Path.join(dir, "001.json"))
    assert Capture.read!(dir) == capture
  end

  @tag :tmp_dir
  test "unknown format_version raises", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "exchanges.json"), ~s({"format_version": 2}))

    assert_raise ArgumentError, ~r/format_version/, fn -> Capture.read!(dir) end
  end
end
