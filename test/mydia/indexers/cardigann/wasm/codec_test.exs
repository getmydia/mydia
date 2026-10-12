defmodule Mydia.Indexers.Cardigann.Wasm.CodecTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.Wasm.Codec
  alias Mydia.Indexers.SearchResult

  defp release(overrides) do
    Map.merge(
      %{
        title: "Paper Harbor 2031 1080p WEB-DL x264",
        guid: "https://x.invalid/t/1",
        "download-url": {:some, "https://x.invalid/dl/1.torrent"},
        "magnet-url": :none,
        "info-url": {:some, "https://x.invalid/t/1"},
        "info-hash": :none,
        size: {:some, 1_610_612_736},
        seeders: {:some, 42},
        peers: {:some, 45},
        grabs: :none,
        "publish-unix": {:some, 1_933_027_200},
        categories: [2000],
        "imdb-id": :none,
        "tmdb-id": :none,
        "tvdb-id": :none,
        "download-volume-factor": {:some, 1.0},
        "upload-volume-factor": {:some, 1.0},
        "minimum-ratio": :none,
        "minimum-seed-time": :none
      },
      overrides
    )
  end

  test "session round-trips" do
    session = %{cookies: %{"sid" => "abc"}, expires_at: ~U[2031-01-01 00:00:00Z]}
    assert Codec.decode_session(Codec.encode_session(session)) == session

    empty = %{cookies: %{}, expires_at: nil}
    assert Codec.decode_session(Codec.encode_session(empty)) == empty
  end

  test "a session result with string keys decodes too" do
    wire = %{"cookies" => [%{"name" => "sid", "value" => "1"}], "expires-unix" => :none}
    assert Codec.decode_session(wire) == %{cookies: %{"sid" => "1"}, expires_at: nil}
  end

  test "settings become name/value records, sorted" do
    assert Codec.encode_settings(%{"password" => "p", "username" => "u"}) ==
             [%{name: "password", value: "p"}, %{name: "username", value: "u"}]
  end

  test "a query encodes options as some/none" do
    q = %{
      kind: :tv,
      term: "x",
      categories: [5000],
      imdb_id: nil,
      tmdb_id: nil,
      tvdb_id: 7,
      season: 2,
      episode: "5",
      limit: nil,
      offset: nil
    }

    assert %{
             kind: :tv,
             categories: [5000],
             "imdb-id": :none,
             "tvdb-id": {:some, 7},
             season: {:some, 2},
             episode: {:some, "5"},
             limit: :none
           } = Codec.encode_query(q)
  end

  test "a release decodes into a SearchResult" do
    assert %SearchResult{
             title: "Paper Harbor 2031 1080p WEB-DL x264",
             size: 1_610_612_736,
             seeders: 42,
             leechers: 3,
             download_url: "https://x.invalid/dl/1.torrent",
             info_url: "https://x.invalid/t/1",
             indexer: "Lantern",
             category: 2000,
             published_at: ~U[2031-04-04 00:00:00Z],
             download_protocol: :torrent
           } = Codec.decode_release(release(%{}), "Lantern")
  end

  test "string-keyed releases decode like atom-keyed ones" do
    stringy = release(%{}) |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)

    assert Codec.decode_release(stringy, "Lantern") ==
             Codec.decode_release(release(%{}), "Lantern")
  end

  test "a magnet-only release uses the magnet as download_url" do
    r =
      release(%{
        "download-url": :none,
        "magnet-url": {:some, "magnet:?xt=urn:btih:abc"},
        seeders: :none,
        peers: :none,
        size: :none,
        "publish-unix": :none
      })

    assert %SearchResult{
             download_url: "magnet:?xt=urn:btih:abc",
             size: 0,
             seeders: nil,
             leechers: nil,
             published_at: nil
           } = Codec.decode_release(r, "X")
  end

  test "download payloads decode bytes and links" do
    session = %{cookies: [], "expires-unix": :none}

    assert %{payload: {:bytes, <<1, 2, 3>>}} =
             Codec.decode_download(%{payload: {:bytes, [1, 2, 3]}, session: session})

    assert %{payload: {:link, "magnet:?x"}} =
             Codec.decode_download(%{payload: {:link, "magnet:?x"}, session: session})
  end

  test "a captcha login decodes its image" do
    challenge = %{image: [1, 2], "content-type": "image/png", state: "st"}

    assert {:captcha, %{image: <<1, 2>>, content_type: "image/png", state: "st"}} =
             Codec.decode_login({:captcha, challenge})
  end

  test "variant cases arrive as kebab-case strings when the atom does not exist yet" do
    assert %{type: :authentication_failed} = Codec.decode_error({"login-failed", "bad"})
    assert %{type: :rate_limited} = Codec.decode_error({"request-limit", "slow"})
    assert %{type: :captcha_required} = Codec.decode_error({"captcha-required", ""})
    assert %{type: :parse_error} = Codec.decode_error({"parse-failed", "x"})

    assert {:ok, %{cookies: %{}}} =
             Codec.decode_login({"ok", %{cookies: [], "expires-unix": :none}})

    assert %{payload: {:link, "magnet:?x"}} =
             Codec.decode_download(%{
               payload: {"link", "magnet:?x"},
               session: %{cookies: [], "expires-unix": :none}
             })
  end

  test "host http errors are told apart by the case the guest names" do
    assert %{type: :timeout} = Codec.decode_error({:http, "timeout: gave up"})
    assert %{type: :connection_failed} = Codec.decode_error({:http, "connect: refused"})

    assert %{type: :network_error, details: %{kind: :blocked}} =
             Codec.decode_error({:http, "blocked: x"})

    assert %{type: :network_error, details: %{kind: :other}} =
             Codec.decode_error({:http, "other: x"})

    assert %{type: :network_error, details: nil} = Codec.decode_error({:http, "Download failed"})
  end

  test "engine errors map to adapter errors" do
    assert %{type: :authentication_failed} = Codec.decode_error({:login_failed, "bad password"})
    assert %{type: :rate_limited} = Codec.decode_error({:request_limit, "slow down"})
    assert %{type: :captcha_required} = Codec.decode_error({:captcha_required, ""})
    assert %{type: :parse_error} = Codec.decode_error({:parse_failed, "no rows"})
    assert %{type: :network_error} = Codec.decode_error({:http, "reset"})
    assert %{type: :api_error} = Codec.decode_error({:cloudflare, "challenge"})

    assert %{type: :engine_error} =
             Codec.decode_error({:internal, "System.NullReferenceException: ..."})
  end
end
