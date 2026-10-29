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

  @tag :tmp_dir
  test "an error kind outside the closed set raises on write and on read", %{tmp_dir: dir} do
    capture = %Capture{
      definition: "example",
      ref: "abc",
      query: %{kind: :rss, term: ""},
      exchanges: [
        %Exchange{request: RequestKey.new(:get, "https://t.example/", nil), error: :bogus}
      ]
    }

    assert_raise ArgumentError, ~r/error kind/, fn -> Capture.write!(capture, dir) end

    File.write!(
      Path.join(dir, "exchanges.json"),
      ~s({"format_version": 1, "definition": "e", "ref": "a", "query": {"kind": "rss", "term": ""},) <>
        ~s("exchanges": [{"request": {"method": "GET", "url": "https://t.example/", "body": null}, "response": {"error": "bogus"}}]})
    )

    assert_raise ArgumentError, ~r/error kind/, fn -> Capture.read!(dir) end
  end

  defp page(n),
    do: %Exchange{
      request: RequestKey.new(:get, "https://t.example/#{n}", nil),
      status: 200,
      headers: [{"content-type", "text/html"}],
      body: "<p>#{n}</p>"
    }

  @tag :tmp_dir
  test "write! replaces what the directory held", %{tmp_dir: dir} do
    capture = %Capture{definition: "e", ref: "r", query: %{kind: :rss, term: ""}}

    Capture.write!(%{capture | exchanges: [page(1), page(2)]}, dir)
    Capture.write!(%{capture | exchanges: [page(3)]}, dir)

    assert Enum.sort(File.ls!(dir)) == ["001.html", "exchanges.json"]
    assert File.read!(Path.join(dir, "001.html")) == "<p>3</p>"
  end

  @tag :tmp_dir
  test "newest_set ranks capture sets by their newest capture", %{tmp_dir: root} do
    capture = %Capture{
      definition: "e",
      ref: "r",
      query: %{kind: :rss, term: ""},
      exchanges: [page(1)]
    }

    for {set, posix} <- [{"old", 1_000}, {"new", 2_000}] do
      dir = Path.join([root, set, "e", "rss"])
      Capture.write!(capture, dir)
      File.touch!(Path.join(dir, "exchanges.json"), posix)
      # The set directory's own mtime says nothing about what is inside it.
      File.touch!(Path.join(root, set), 3_000 - posix)
    end

    assert Capture.newest_set(root) == Path.join(root, "new")

    # Re-recording into the older set makes it the newest.
    File.touch!(Path.join([root, "old", "e", "rss", "exchanges.json"]), 4_000)
    assert Capture.newest_set(root) == Path.join(root, "old")

    assert Capture.newest_set(Path.join(root, "missing")) == nil
  end
end
