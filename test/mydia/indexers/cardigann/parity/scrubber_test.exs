defmodule Mydia.Indexers.Cardigann.Parity.ScrubberTest do
  use Mydia.DataCase, async: false

  alias Mydia.Indexers.CardigannParser
  alias Mydia.Indexers.Cardigann.Parity.{Capture, Fictional, RequestKey, Runner, Scrubber}
  alias Mydia.Indexers.Cardigann.Parity.Capture.Exchange
  alias Mydia.Indexers.Cardigann.Parity.Scrubber.Ids
  alias Mydia.Indexers.Cardigann.Wasm.{Artifact, Engine}

  @yaml """
  id: harbor
  name: Harbor
  description: Invented tracker for parity tests
  language: en-US
  type: public
  encoding: UTF-8
  links:
    - https://harbor.invalid/
  caps:
    categorymappings:
      - {id: 1, cat: Movies, desc: Movies}
    modes:
      search: [q]
  settings: []
  search:
    paths:
      - path: search
    inputs:
      q: "{{ .Keywords }}"
    rows:
      selector: tr.row
    fields:
      title:
        selector: td.t a
      details:
        selector: td.t a
        attribute: href
      download:
        selector: td.d a
        attribute: href
      category:
        text: "1"
      size:
        selector: td.s
      seeders:
        selector: td.se
  """

  @page """
  <!DOCTYPE html>
  <html><head><meta charset="utf-8"><title>Harbor</title></head><body>
  <ul class="popular"><li>Thimble Gantry 2030 1080p</li></ul>
  <table class="results"><tbody>
  <tr class="head"><th>Name</th></tr>
  <tr class="row"><td class="t"><a href="/t/1/Mellow-Kiln">Mellow Kiln 2031 1080p WEB</a></td>
  <td class="d"><a href="/dl/1.torrent">dl</a></td><td class="s">1.5 GB</td><td class="se">42</td></tr>
  <tr class="row"><td class="t"><a href="/t/2/Drowsy-Weir">Drowsy Weir S01E02 720p HDTV</a></td>
  <td class="d"><a href="/dl/2.torrent">dl</a></td><td class="s">700 MB</td><td class="se">7</td></tr>
  </tbody></table>
  <div class="footer">Copyright</div>
  </body></html>
  """

  defp parsed(yaml \\ @yaml) do
    {:ok, parsed} = CardigannParser.parse_definition(yaml)
    parsed
  end

  defp exchange(body, opts \\ []) do
    %Exchange{
      request:
        RequestKey.new("GET", Keyword.get(opts, :url, "https://harbor.invalid/search?q=x"), nil),
      status: Keyword.get(opts, :status, 200),
      headers: [
        {"content-type", Keyword.get(opts, :type, "text/html")},
        {"content-length", Integer.to_string(byte_size(body))}
      ],
      body: body
    }
  end

  defp capture(exchanges),
    do: %Capture{
      definition: "harbor",
      ref: "test",
      query: %{kind: :generic, term: "x"},
      exchanges: exchanges
    }

  defp content_length(%Exchange{headers: headers}),
    do: headers |> List.keyfind("content-length", 0) |> elem(1) |> String.to_integer()

  describe "rename/2" do
    test "replaces every encoded form of the work and keeps unrelated text" do
      body = """
      <a>Copper &amp; Vale 2031</a> q=Copper+%26+Vale q2=Copper%20%26%20Vale
      Copper & Vale
      slug /t/Copper-Vale/ dot Copper.Vale under Copper_Vale lower copper-vale
      unrelated Harbor text
      """

      {%Capture{exchanges: [ex]}, works} =
        Scrubber.rename(capture([exchange(body)]), ["Copper & Vale 2031 1080p"])

      assert works == ["Copper & Vale"]
      fake = Fictional.name("Copper & Vale")
      [a, b] = String.split(fake, " ")

      refute ex.body =~ ~r/copper|vale/i
      assert ex.body =~ "<a>#{fake} 2031</a>"
      assert ex.body =~ "q=#{a}+#{b}"
      assert ex.body =~ "q2=#{a}%20#{b}"
      assert ex.body =~ "/t/#{a}-#{b}/"
      assert ex.body =~ "dot #{a}.#{b}"
      assert ex.body =~ "under #{a}_#{b}"
      assert ex.body =~ "lower #{String.downcase(a)}-#{String.downcase(b)}"
      assert ex.body =~ "unrelated Harbor text"
      assert content_length(ex) == byte_size(ex.body)
    end

    test "matches the work in any case and keeps lowercase lowercase" do
      body = ~s(<a>pebbleos-2031.12-x86_64.iso</a><span class="badge">PebbleOS</span>)

      {%Capture{exchanges: [ex]}, ["pebbleos"]} =
        Scrubber.rename(capture([exchange(body)]), ["pebbleos-2031.12-x86_64.iso"])

      # A one-word work gets a one-word name, so no space lands in a slug.
      fake = "pebbleos" |> Fictional.name() |> String.replace(" ", "")
      refute ex.body =~ ~r/pebbleos/i
      assert ex.body =~ "<a>#{String.downcase(fake)}-2031.12"
      assert ex.body =~ ~s(<span class="badge">#{fake}</span>)
    end

    test "leaves `keep:` words alone, ignoring case" do
      body = ~s(<a>pebbleos-2031.12.iso</a><span class="badge">PebbleOS</span>)

      assert {%Capture{exchanges: [%Exchange{body: ^body}]}, []} =
               Scrubber.rename(capture([exchange(body)]), ["pebbleos-2031.12.iso"],
                 keep: ["PebbleOS"]
               )
    end

    test "renames other apostrophe entities and the apostrophe-dropped slug" do
      body = "Pim&#039;s Fennel | Pim&apos;s Fennel | Pim&#x27;s Fennel | /t/pims-fennel/"

      {%Capture{exchanges: [ex]}, ["Pim's Fennel"]} =
        Scrubber.rename(capture([exchange(body)]), ["Pim's Fennel 2031 1080p"])

      refute ex.body =~ ~r/pim|fennel/i
    end

    test "renames the longest work first" do
      body = "Old Mellow Kiln and Mellow Kiln"

      {%Capture{exchanges: [ex]}, works} =
        Scrubber.rename(capture([exchange(body)]), ["Mellow Kiln 2031", "Old Mellow Kiln 2030"])

      assert Enum.sort(works) == ["Mellow Kiln", "Old Mellow Kiln"]

      assert ex.body ==
               "#{Fictional.name("Old Mellow Kiln")} and #{Fictional.name("Mellow Kiln")}"
    end

    test "renames a work however its words are joined" do
      body = """
      <title>Kiln: Pim's Fennel</title>
      dn=%5BGrp%5D%20Kiln%20Pim&apos;s%20Fennel%20S01E02
      dn=Kiln%20Pim's%20Fennel!
      """

      {%Capture{exchanges: [ex]}, works} =
        Scrubber.rename(capture([exchange(body)]), ["Kiln Pim's Fennel S01E02 1080p"])

      assert "Kiln Pim's Fennel" in works
      refute ex.body =~ ~r/kiln|pim|fennel/i
      [a, b] = "Kiln Pim's Fennel" |> Fictional.name() |> String.split(" ")
      assert ex.body =~ "%5BGrp%5D%20#{a}%20#{b}%20S01E02"
    end

    test "renames bracketed, slashed, listed and composed names, and episode titles" do
      titles = [
        "[Grp] Quiet Sorrel S02 / Ruhige Sauerampfer - 04 [1080p][WEB-DL][AAC AVC][CHT]",
        "[Grp][Lumen Vale][03][1080p]",
        "Tarn Ferry S01E04 1080p CR WEB-DL AAC2.0 x264-Grp (VOSTFR, Tarn no Fune, Ferry Tarn)",
        "Bosk Hollow S01E02 The Long Way Home 1080p WEB-DL",
        "Gorse Engine - Nintendo Switch",
        "[Grp][深井 鏡\\Fukai Kagami\\DEEP MIRROR][BDRip][1080P]"
      ]

      {_capture, works} = Scrubber.rename(capture([exchange("x")]), titles)

      names = [
        "Ruhige Sauerampfer",
        "Lumen Vale",
        "Tarn no Fune",
        "Ferry Tarn",
        "The Long Way Home",
        "Gorse Engine",
        "Nintendo Switch",
        "Fukai Kagami",
        "DEEP MIRROR"
      ]

      for name <- names, do: assert(name in works, "#{name} missing from #{inspect(works)}")

      # Release vocabulary and short tags are not names.
      for tag <- ["VOSTFR", "AAC AVC", "CHT", "Grp", "x264-Grp"],
          do: refute(tag in works)
    end

    test "renames a work in a slug that strips or drops its accented letters" do
      body =
        "/view/1_Kiln_wa_Mosa_Shindo_04.html /view/2_Kiln_wa_Msa_Shindo_04.html " <>
          "/view/3_Kiln_wa_M_sa_Shindo_04.html"

      {%Capture{exchanges: [ex]}, _} =
        Scrubber.rename(capture([exchange(body)]), ["Kiln wa Mōsa Shindo - 04 [1080p]"])

      refute ex.body =~ ~r/kiln|shindo/i
    end

    test "renames a Latin work with many accents in a slug that strips them" do
      body = "/movies/kilna-sorrel-dawn-2031 /img/kilna_sorrel_dawn_2031/cover.jpg"

      {%Capture{exchanges: [ex]}, _} =
        Scrubber.rename(capture([exchange(body)]), ["Kilnâ Sorrêl Dâwn 2031 1080p"])

      refute ex.body =~ ~r/kilna|sorrel|dawn/i
    end

    test "learns the name before a subtitle colon, and its acronym slugged without dots" do
      body = ~s(<a href="/2702-kiln-2-2031.html">x</a>)

      {%Capture{exchanges: [ex]}, works} =
        Scrubber.rename(capture([exchange(body)]), [
          "K.I.L.N. 2: Heart of Tarn - Ultimate Edition"
        ])

      assert "K.I.L.N. 2" in works
      refute ex.body =~ ~r/kiln/i
    end

    test "learns the Latin part of a name written in two scripts, and slugged ×" do
      body = "/view/1_Kiln_Spirits_4.html /g/drover-x-drover-tide"

      {%Capture{exchanges: [ex]}, works} =
        Scrubber.rename(capture([exchange(body)]), [
          "[Grp] Kiln Spirits 港灣燈塔 [4] - Re [1080P]",
          "Drover × Drover: Tide - Nintendo Switch"
        ])

      assert "Kiln Spirits" in works
      refute ex.body =~ ~r/kiln|spirits|drover/i
    end

    test "never cuts a CJK work down to a fragment that renames part of another" do
      body = "Kiln no Gavani: U-17 Harbor Cup"

      {%Capture{exchanges: [ex]}, _} =
        Scrubber.rename(capture([exchange(body)]), [
          "新港灣燈塔 U-17 HARBOR CUP 燈塔杯決賽 - 05 [1080P]",
          "Kiln no Gavani: U-17 Harbor Cup S05E05 1080p"
        ])

      refute ex.body =~ ~r/kiln|gavani|harbor/i
      assert ex.body == "Kiln no Gavani: U-17 Harbor Cup" |> Fictional.name()
    end

    test "never turns a CJK tag into a digits-only spelling that would hit a date" do
      body = "<span>2026/10/29 01:15</span>"

      {%Capture{exchanges: [ex]}, _} =
        Scrubber.rename(capture([exchange(body)]), ["[Grp] Kiln wa Mosa [03] [2026年10月番]"])

      assert ex.body == body
    end

    test "renames a truncated work in a windows-1251 page, taking its whole last word" do
      body = "Тихая Гавань / Я их настоящих (2031) WEB-DL"
      cp1251 = Mydia.Indexers.Cardigann.Charset.encode(body, "windows-1251")

      {%Capture{exchanges: [ex]}, _} =
        Scrubber.rename(capture([exchange(cp1251)]), ["Тихая Гавань / Я их нас …"],
          encoding: "windows-1251"
        )

      text = Mydia.Indexers.Cardigann.Charset.decode(ex.body, "windows-1251")
      refute text =~ "настоящих"
      refute text =~ "Тихая"
      assert text =~ "(2031) WEB-DL"
    end

    test "renames a longer work before a shorter one that starts it" do
      body = ~s({"title":"Kilnworth 2: Grumme Tide","other":"Kilnworth"})

      {%Capture{exchanges: [ex]}, works} =
        Scrubber.rename(capture([exchange(body, type: "application/json")]), [
          "Kilnworth 2031 1080p",
          "Kilnworth 2 Grumme Tide 2031 1080p"
        ])

      assert "Kilnworth" in works and "Kilnworth 2 Grumme Tide" in works
      refute ex.body =~ ~r/kilnworth|grumme|tide/i
    end

    test "learns a segment without the numbered prefix a title filter rewrote" do
      body = "Выпуск 695. Festa na Tihoj Gavani (23.10.2031)"

      {%Capture{exchanges: [ex]}, works} =
        Scrubber.rename(capture([exchange(body)]), [
          "Grumme Club /E695. Festa na Tihoj Gavani (23.10.2031) WEB-DL 1080p"
        ])

      assert "Festa na Tihoj Gavani" in works
      refute ex.body =~ ~r/festa|gavani/i
      assert ex.body =~ "(23.10.2031)"
    end

    test "cuts a work before a bracketed date, so the date survives renaming" do
      {%Capture{exchanges: [ex]}, works} =
        Scrubber.rename(capture([exchange("Kiln Harbor (21.04.2031) WEB-DL")]), [
          "Kiln Harbor (21.04.2031) WEB-DL 1080p"
        ])

      assert "Kiln Harbor" in works
      refute Enum.any?(works, &String.contains?(&1, "("))
      assert ex.body =~ ~r/ \(21\.04\.2031\) WEB-DL\z/
    end

    test "renames request URLs too, so a followed link still replays" do
      ex = exchange("x", url: "https://harbor.invalid/t/1/Mellow-Kiln")
      {%Capture{exchanges: [renamed]}, _} = Scrubber.rename(capture([ex]), ["Mellow Kiln 2031"])

      refute renamed.request.url =~ "Mellow"
    end

    test "leaves exchanges without a body alone" do
      error = %Exchange{
        request: RequestKey.new("GET", "https://harbor.invalid/", nil),
        error: :timeout
      }

      {%Capture{exchanges: [same]}, _} = Scrubber.rename(capture([error]), ["Mellow Kiln 2031"])
      assert same == error
    end
  end

  describe "trim/2" do
    test "keeps only the rows and their ancestors" do
      trimmed = Scrubber.trim(capture([exchange(@page)]), parsed())
      [ex] = trimmed.exchanges

      refute ex.body =~ "popular"
      refute ex.body =~ "Thimble Gantry"
      refute ex.body =~ "footer"
      refute ex.body =~ "data-mydia"
      assert ex.body =~ ~r/^<!DOCTYPE html>/i
      assert ex.body =~ ~s(<meta charset="utf-8")

      doc = LazyHTML.from_document(ex.body)
      assert Enum.count(LazyHTML.query(doc, "table.results tr.row")) == 2
      assert Enum.empty?(LazyHTML.query(doc, "tr.head"))
      assert content_length(ex) == byte_size(ex.body)
    end

    test "keeps a content-type meta but drops a refresh meta" do
      page =
        String.replace(
          @page,
          ~s(<meta charset="utf-8">),
          ~s(<meta http-equiv="Content-Type" content="text/html; charset=utf-8">) <>
            ~s(<meta http-equiv="refresh" content="0; url=/t/9/Thimble-Gantry">)
        )

      [ex] = Scrubber.trim(capture([exchange(page)]), parsed()).exchanges
      assert ex.body =~ ~s(http-equiv="Content-Type")
      refute ex.body =~ "refresh"
      refute ex.body =~ "Thimble"
    end

    test "keeps the rows an `after:` block joins to each match" do
      yaml =
        String.replace(@yaml, "    selector: tr.row\n", "    selector: tr.row\n    after: 1\n")

      page =
        String.replace(
          @page,
          ~s(<tr class="row">),
          ~s(<tr class="row"><td>x</td></tr><tr class="extra">)
        )

      [ex] = Scrubber.trim(capture([exchange(page)]), parsed(yaml)).exchanges
      assert Enum.count(LazyHTML.query(LazyHTML.from_document(ex.body), "tr.extra")) == 2
    end

    test "keeps only the rows path of a JSON body" do
      yaml = String.replace(@yaml, "    selector: tr.row\n", "    selector: data.items\n")

      json =
        Jason.encode!(%{
          "data" => %{"items" => [%{"name" => "a"}, %{"name" => "b"}], "total" => 2},
          "popular" => [%{"name" => "Thimble Gantry"}]
        })

      [ex] =
        Scrubber.trim(capture([exchange(json, type: "application/json")]), parsed(yaml)).exchanges

      assert Jason.decode!(ex.body) == %{
               "data" => %{"items" => [%{"name" => "a"}, %{"name" => "b"}]}
             }
    end

    test "cuts JSON rows down to the keys a field selector reads" do
      yaml =
        @yaml
        |> String.replace(
          "    selector: tr.row\n",
          "    selector: data.items\n    attribute: files\n"
        )
        |> String.replace(~r/  fields:\n.*\z/s, """
          fields:
            title:
              selector: ..name
            size:
              selector: bytes
            seeders:
              selector: stats.seeds
        """)

      json =
        Jason.encode!(%{
          "data" => %{
            "items" => [
              %{
                "name" => "a",
                "summary" => "Thimble Gantry, the plot",
                "stats" => %{"seeds" => 3, "cast" => ["Someone"]},
                "files" => [%{"bytes" => 10, "note" => "Thimble Gantry"}]
              }
            ]
          }
        })

      [ex] =
        Scrubber.trim(capture([exchange(json, type: "application/json")]), parsed(yaml)).exchanges

      assert Jason.decode!(ex.body) == %{
               "data" => %{
                 "items" => [
                   %{"name" => "a", "stats" => %{"seeds" => 3}, "files" => [%{"bytes" => 10}]}
                 ]
               }
             }
    end

    test "does not touch failed exchanges or pages without rows" do
      failed = exchange(@page, status: 500)
      login = exchange("<html><body><form id=login></form></body></html>")

      error = %Exchange{
        request: RequestKey.new("GET", "https://harbor.invalid/", nil),
        error: :timeout
      }

      assert {%Capture{exchanges: [^failed, ^login, ^error]}, notes} =
               Scrubber.trim_with_notes(capture([failed, login, error]), parsed())

      # Every body written whole is reported; the transport error has none.
      assert [http, rows] = notes
      assert http =~ "exchange 1" and http =~ "HTTP 500"
      assert rows =~ "exchange 2" and rows =~ "matches nothing"
    end

    test "reports a JSON body whose rows are the whole document" do
      yaml = String.replace(@yaml, "    selector: tr.row\n", "    selector: $\n")
      json = exchange(Jason.encode!([%{"name" => "a"}]), type: "application/json")

      assert {%Capture{exchanges: [^json]}, [note]} =
               Scrubber.trim_with_notes(capture([json]), parsed(yaml))

      assert note =~ "written untrimmed"
    end

    test "keeps the body when the selector cannot be evaluated, and says so" do
      yaml = String.replace(@yaml, "    selector: tr.row\n", "    selector: \"tr:eq(0)\"\n")
      ex = exchange(@page)

      assert {%Capture{exchanges: [^ex]}, [note]} =
               Scrubber.trim_with_notes(capture([ex]), parsed(yaml))

      assert note =~ "untrimmed"
    end

    test "re-encodes a windows-1251 body into its own charset" do
      yaml = String.replace(@yaml, "encoding: UTF-8", "encoding: windows-1251")
      utf8 = String.replace(@page, "Mellow Kiln", "Тихая Гавань")
      cp1251 = Mydia.Indexers.Cardigann.Charset.encode(utf8, "windows-1251")
      refute cp1251 == utf8

      [ex] = Scrubber.trim(capture([exchange(cp1251)]), parsed(yaml)).exchanges
      refute ex.body =~ "popular"
      assert ex.body =~ Mydia.Indexers.Cardigann.Charset.encode("Тихая Гавань", "windows-1251")
    end
  end

  describe "strip_scripts" do
    alias Mydia.Indexers.Cardigann.Parity.Scrubber.Trim

    test "drops scripts and stylesheet or preload links from an HTML body" do
      body = """
      <html><head><link rel="stylesheet" href="https://cdn.invalid/a.css">
      <link rel="icon" href="/f.ico">
      <script src="https://cdn.invalid/a.js"></script></head><body>
      <script>var x = "</div>";</script><p>kept</p></body></html>
      """

      %Exchange{body: out} = Trim.strip_scripts(exchange(body), "UTF-8")

      refute out =~ "<script"
      refute out =~ "stylesheet"
      assert out =~ ~s(rel="icon")
      assert out =~ "<p>kept</p>"
    end

    test "leaves a JSON body that mentions a script alone" do
      ex = exchange(~s({"a":"<script>x</script>"}), type: "application/json")
      assert Trim.strip_scripts(ex, "UTF-8") == ex
    end
  end

  describe "scrub_ids/1" do
    @hash "a3023d03c85bf18860ce17fad6f9ee3403d0633b"
    @upper String.upcase(@hash)

    defp id_body,
      do: """
      <a href="magnet:?xt=urn:btih:#{@upper}&dn=x">m</a> /dl/#{@hash}.torrent
      copy="magnet%3A%3Fxt%3Durn%3Abtih%3A#{@hash}"
      magnet:?xt=urn:btih:HKIAFWHSKW5ZPADKF5KBWWGSHQHNBOIB&dn=
      <torznab:attr name="tmdbid" value="2000104642" /><torznab:attr name="size" value="2000104642" />
      {"imdb_code":"tt200012345","tvdb_id": 2000081189}
      """

    test "replaces ids and hashes with stable stand-ins, keeping a hash's case" do
      {%Capture{exchanges: [ex]}, ids} = Scrubber.scrub_ids(capture([exchange(id_body())]))

      standin = Map.fetch!(ids, @hash)
      assert standin =~ ~r/\A[0-9a-f]{40}\z/ and standin != @hash
      assert ex.body =~ "btih:#{String.upcase(standin)}&"
      assert ex.body =~ "/dl/#{standin}.torrent"
      assert ex.body =~ "btih%3A#{standin}"
      assert ex.body =~ ~r/btih:[A-Z2-7]{32}&/
      refute ex.body =~ "HKIAFWHSKW5ZPADKF5KBWWGSHQHNBOIB"
      assert [_, imdb] = Regex.run(~r/"imdb_code":"(tt\d+)"/, ex.body)
      assert imdb =~ ~r/\Att2\d{8}\z/
      assert [_, tmdb] = Regex.run(~r/name="tmdbid" value="(\d+)"/, ex.body)
      assert tmdb =~ ~r/\A20\d{8}\z/ and String.to_integer(tmdb) < 2_147_483_647
      refute ex.body =~ ~s(name="tmdbid" value="2000104642")
      # A size is not an id, even when the number matches.
      assert ex.body =~ ~s(name="size" value="2000104642")
      refute ex.body =~ "2000081189"
      assert content_length(ex) == byte_size(ex.body)

      # Deterministic, and nothing original is left.
      assert {_, ^ids} = Scrubber.scrub_ids(capture([exchange(id_body())]))
      assert Ids.leftovers(ex.body, ids) == []
    end

    test "replaces a capitalised IMDb id and a provider key without an id suffix" do
      body = ~s(<td>IMDb: TT0123456</td> {"tmdb": 123456, "tvdb_id": 654321, "size": 123456})
      {%Capture{exchanges: [ex]}, ids} = Scrubber.scrub_ids(capture([exchange(body)]))

      standin = Map.fetch!(ids, "tt0123456")
      assert ex.body =~ "IMDb: #{String.upcase(standin)}</td>"
      assert [_, tmdb] = Regex.run(~r/"tmdb": (\d+)/, ex.body)
      assert tmdb =~ ~r/\A20\d{8}\z/
      refute ex.body =~ "654321"
      # A size is not an id, even when the number matches.
      assert ex.body =~ ~s("size": 123456)
      assert Ids.leftovers(ex.body, ids) == []
      assert Ids.leftovers("IMDb: TT0123456", ids) == ["tt0123456"]
    end

    test "translates what the original replay yielded" do
      {_, ids} = Scrubber.scrub_ids(capture([exchange(id_body())]))

      assert Ids.translate(2_000_104_642, ids) == String.to_integer(Map.fetch!(ids, "2000104642"))
      assert Ids.translate("tt200012345", ids) == Map.fetch!(ids, "tt200012345")
      assert Ids.translate(@upper, ids) == String.upcase(Map.fetch!(ids, @hash))
      assert Ids.translate(7, ids) == 7
    end

    test "verify fails on an original id or hash that survived" do
      {_, ids} = Scrubber.scrub_ids(capture([exchange(id_body())]))
      empty = %{wasm: {:ok, []}, wasm_misses: []}
      cap = capture([exchange("left: tt200012345 and #{@upper}")])

      assert {:error, errors} = Scrubber.verify(empty, empty, [], cap, ids: ids)
      assert Enum.any?(errors, &(&1 =~ "tt200012345"))
      assert Enum.any?(errors, &(&1 =~ @hash))
    end
  end

  describe "learned_titles/1" do
    test "takes titles from both engines, so a row only native parses is renamed too" do
      wasm = %{title: "Mellow Kiln 2031 1080p"}
      native = %{title: "Drowsy Weir S01E02 720p"}

      assert {:ok, ["Mellow Kiln 2031 1080p", "Drowsy Weir S01E02 720p"]} =
               Scrubber.learned_titles(%{wasm: {:ok, [wasm]}, native: {:ok, [native]}})

      assert {:ok, ["Mellow Kiln 2031 1080p"]} =
               Scrubber.learned_titles(%{wasm: {:ok, [wasm]}, native: {:error, :boom}})

      assert {:error, [_]} = Scrubber.learned_titles(%{wasm: {:error, :boom}, native: {:ok, []}})
    end
  end

  describe "verify/5 leak checks" do
    # No parsing to compare, so these need no engine.
    @empty %{wasm: {:ok, []}, wasm_misses: []}

    defp leaks(body, works, opts \\ []) do
      cap = capture([exchange(body, opts)])
      Scrubber.verify(@empty, @empty, works, cap, Keyword.take(opts, [:encoding]))
    end

    test "translates only id fields, so a seeders count equal to an id stays as it was" do
      row = fn tmdb ->
        Mydia.Indexers.SearchResult.new(
          title: "Mellow Kiln",
          size: 1000,
          seeders: 20,
          leechers: 2,
          download_url: "https://harbor.invalid/dl/1.torrent",
          indexer: "x",
          category: 2000,
          metadata: %{tmdb_id: tmdb}
        )
      end

      ids = %{"20" => "2012345678"}
      before = %{wasm: {:ok, [row.(20)]}, wasm_misses: []}
      now = %{wasm: {:ok, [row.(2_012_345_678)]}, wasm_misses: []}
      cap = capture([exchange("x")])

      # The id field is expected to come back as its stand-in; seeders is not.
      assert Scrubber.verify(before, now, [], cap, ids: ids) == :ok
    end

    test "finds a work behind a padded apostrophe entity" do
      assert {:error, [msg]} = leaks("<a>Kiln&#039;s Harbor</a>", ["Kiln's Harbor"])
      assert msg =~ "body 1"
    end

    test "finds a work in a slug that drops the apostrophe" do
      assert {:error, [_]} = leaks(~s(<a href="/t/kilns-harbor/">x</a>), ["Kiln's Harbor"])
    end

    test "finds a work percent-encoded twice" do
      assert {:error, [_]} = leaks("/search?q=Mellow%2520Kiln", ["Mellow Kiln"])
    end

    test "finds a work in JSON escapes and named entities" do
      assert {:error, [_]} = leaks(~S({"t":"Café Mellow"}), ["Café Mellow"])
      assert {:error, [_]} = leaks("Caf&eacute; Mellow", ["CAFÉ MELLOW"])
    end

    test "finds what is left of a work renamed only in part" do
      assert {:error, [msg]} = leaks("CopperKiln 2: Grumme Tide", ["Kilnworth 2 Grumme Tide"])
      assert msg =~ "in part: grummetide"
    end

    test "finds a work in a response header" do
      ex = exchange("clean")
      ex = %{ex | headers: [{"content-disposition", "attachment; filename=Mellow.Kiln.torrent"}]}

      assert {:error, [msg]} = Scrubber.verify(@empty, @empty, ["Mellow Kiln"], capture([ex]))
      assert msg =~ "header content-disposition"
    end

    test "finds a work in a request body" do
      ex = %{
        exchange("clean")
        | request: RequestKey.new("POST", "https://harbor.invalid/search", "q=Mellow%2BKiln")
      }

      assert {:error, [msg]} = Scrubber.verify(@empty, @empty, ["Mellow Kiln"], capture([ex]))
      assert msg =~ "request 1 body"
    end

    test "finds an accented work in a slug that strips its accents" do
      assert {:error, [_]} = leaks("/movies/kilna-sorrel-dawn-2031", ["Kilnâ Sorrêl Dâwn"])
    end

    test "passes clean text" do
      assert leaks("<a>Lantern Quay</a>", ["Mellow Kiln"]) == :ok
    end

    test "renames and verifies a windows-1251 work, including its percent-encoded link" do
      work = "Тихая Гавань"
      cp = &Mydia.Indexers.Cardigann.Charset.encode(&1, "windows-1251")
      link = URI.encode_www_form(cp.(work))
      body = cp.("<a href=\"/search?q=") <> link <> cp.("\">#{work} 2031</a>")

      assert {:error, _} = leaks(body, [work], encoding: "windows-1251")

      {renamed, [^work]} =
        Scrubber.rename(capture([exchange(body)]), ["#{work} 2031 1080p"],
          encoding: "windows-1251"
        )

      assert Scrubber.verify(@empty, @empty, [work], renamed, encoding: "windows-1251") == :ok
      [ex] = renamed.exchanges
      assert ex.body =~ URI.encode_www_form(Fictional.name(work))
    end

    @tag :tmp_dir
    test "seed reports a malformed capture instead of crashing", %{tmp_dir: tmp} do
      dir = Path.join([tmp, "harbor", "generic"])
      File.mkdir_p!(dir)
      File.write!(Path.join(tmp, "harbor/definition.yml"), @yaml)
      File.write!(Path.join(dir, "exchanges.json"), ~s({"format_version": 99}))

      assert {:error, [msg]} = Scrubber.seed(dir, Path.join(tmp, "out"))
      assert msg =~ "cannot read the capture" and msg =~ dir
    end
  end

  describe "verify/5 and seed/3" do
    @describetag :cardigann_wasm
    @describetag timeout: 300_000

    setup do
      :ok = Engine.ensure_started()

      on_exit(fn ->
        Supervisor.terminate_child(Mydia.Supervisor, Engine)
        Supervisor.delete_child(Mydia.Supervisor, Engine)
      end)

      unless Engine.available?() do
        flunk("cardigann.wasm unavailable (#{inspect(Artifact.load())})")
      end

      original = Application.get_env(:mydia, :features, [])
      Application.put_env(:mydia, :features, cardigann_enabled: true)
      on_exit(fn -> Application.put_env(:mydia, :features, original) end)

      assert :ok = Runner.prepare_definition("harbor", @yaml)
      :ok
    end

    test "a scrub that keeps parsing and removes every work passes" do
      cap = capture([exchange(@page)])
      original = Runner.replay(cap)
      {renamed, works} = Scrubber.rename(Scrubber.trim(cap, parsed()), titles(original))
      scrubbed = Runner.replay(renamed)

      assert Scrubber.verify(original, scrubbed, works, renamed) == :ok

      # verify/5 leaves the links alone (renaming changes them), so check here
      # that only the work's slug changed.
      slug = fn work -> work |> Fictional.name() |> String.replace(" ", "-") end
      {:ok, results} = scrubbed.wasm

      assert Enum.map(results, &{&1.info_url, &1.download_url}) == [
               {"https://harbor.invalid/t/1/#{slug.("Mellow Kiln")}",
                "https://harbor.invalid/dl/1.torrent"},
               {"https://harbor.invalid/t/2/#{slug.("Drowsy Weir")}",
                "https://harbor.invalid/dl/2.torrent"}
             ]
    end

    test "a scrub that drops a row's size cell fails" do
      cap = capture([exchange(@page)])
      original = Runner.replay(cap)
      broken = capture([exchange(String.replace(@page, ~s(<td class="s">700 MB</td>), ""))])
      {renamed, works} = Scrubber.rename(broken, titles(original))

      assert {:error, errors} = Scrubber.verify(original, Runner.replay(renamed), works, renamed)
      # The wasm engine drops a row without a size, so this reads as a lost result.
      assert Enum.any?(errors, &(&1 =~ "results"))
    end

    test "a scrub that changes a row's size fails on that field" do
      cap = capture([exchange(@page)])
      original = Runner.replay(cap)
      broken = capture([exchange(String.replace(@page, "700 MB", "70 MB"))])
      {renamed, works} = Scrubber.rename(broken, titles(original))

      assert {:error, errors} = Scrubber.verify(original, Runner.replay(renamed), works, renamed)
      assert Enum.any?(errors, &(&1 =~ "result 2 size"))
    end

    test "a body still holding a work fails" do
      cap = capture([exchange(@page)])
      original = Runner.replay(cap)

      assert {:error, errors} =
               Scrubber.verify(original, original, ["Mellow Kiln", "Drowsy Weir"], cap)

      assert Enum.any?(errors, &(&1 =~ "Mellow Kiln"))
    end

    test "an over-size body fails" do
      cap = capture([exchange(@page)])
      original = Runner.replay(cap)

      padded =
        String.replace(@page, "</body>", "<!-- #{String.duplicate("x", 600_000)} --></body>")

      big = capture([exchange(padded)])

      assert {:error, errors} = Scrubber.verify(original, Runner.replay(big), [], big)
      assert Enum.any?(errors, &(&1 =~ "bytes"))
    end

    @tag :tmp_dir
    test "seed writes a scrubbed capture and the definition", %{tmp_dir: tmp} do
      cache = Path.join([tmp, "cache", "harbor"])
      File.mkdir_p!(cache)
      File.write!(Path.join(cache, "definition.yml"), @yaml)
      Capture.write!(capture([exchange(@page)]), Path.join(cache, "generic"))

      out = Path.join(tmp, "out")
      assert {:ok, _notes} = Scrubber.seed(Path.join(cache, "generic"), out)

      assert File.read!(Path.join(out, "definition.yml")) == @yaml
      written = Capture.read!(Path.join(out, "generic"))
      [ex] = written.exchanges
      refute ex.body =~ ~r/mellow|kiln|drowsy|weir|popular/i
    end

    @tag :tmp_dir
    test "seed writes nothing when verification fails", %{tmp_dir: tmp} do
      cache = Path.join([tmp, "cache", "harbor"])
      File.mkdir_p!(cache)
      File.write!(Path.join(cache, "definition.yml"), @yaml)
      # The work also names the tracker's search path, which rename cannot touch
      # without the replay missing, so the work survives and verify fails.
      page = String.replace(@page, "Mellow Kiln", "Search")

      Capture.write!(capture([exchange(page)]), Path.join(cache, "generic"))
      out = Path.join(tmp, "out")

      assert {:error, errors} = Scrubber.seed(Path.join(cache, "generic"), out)
      assert Enum.any?(errors, &(&1 =~ ~r/"Search"|unrecorded/))
      refute File.exists?(out)
    end

    @tag :tmp_dir
    test "seed refuses titles with no renamable work", %{tmp_dir: tmp} do
      for {title, work} <- [{"Mellow Kiln 2031", "Up 2031"}, {"Drowsy Weir S01E02", "S01E02"}] do
        cache = Path.join([tmp, "cache", "harbor"])
        File.rm_rf!(cache)
        File.mkdir_p!(cache)
        File.write!(Path.join(cache, "definition.yml"), @yaml)
        page = String.replace(@page, title, work)
        Capture.write!(capture([exchange(page)]), Path.join(cache, "generic"))
        out = Path.join(tmp, "out")

        assert {:error, errors} = Scrubber.seed(Path.join(cache, "generic"), out)
        assert Enum.any?(errors, &(&1 =~ "no renamable work"))
        refute File.exists?(out)
      end
    end

    @tag :tmp_dir
    test "seed with trim: false notes every body it writes whole", %{tmp_dir: tmp} do
      cache = Path.join([tmp, "cache", "harbor"])
      File.mkdir_p!(cache)
      File.write!(Path.join(cache, "definition.yml"), @yaml)
      Capture.write!(capture([exchange(@page)]), Path.join(cache, "generic"))

      assert {:ok, [note]} =
               Scrubber.seed(Path.join(cache, "generic"), Path.join(tmp, "out"), trim: false)

      assert note =~ "exchange 1" and note =~ "--no-trim"
    end
  end

  describe "seed/3 scripts and vocabulary" do
    @describetag :cardigann_wasm
    @describetag timeout: 300_000

    setup do
      :ok = Engine.ensure_started()

      on_exit(fn ->
        Supervisor.terminate_child(Mydia.Supervisor, Engine)
        Supervisor.delete_child(Mydia.Supervisor, Engine)
      end)

      original = Application.get_env(:mydia, :features, [])
      Application.put_env(:mydia, :features, cardigann_enabled: true)
      on_exit(fn -> Application.put_env(:mydia, :features, original) end)
      :ok
    end

    @tag :tmp_dir
    test "seed drops scripts even from a body it keeps whole", %{tmp_dir: tmp} do
      cache = Path.join([tmp, "cache", "harbor"])
      File.mkdir_p!(cache)
      File.write!(Path.join(cache, "definition.yml"), @yaml)

      page =
        String.replace(
          @page,
          "</head>",
          ~s(<script src="https://cdn.invalid/a.js"></script></head>)
        )

      Capture.write!(capture([exchange(page)]), Path.join(cache, "generic"))

      assert {:ok, _notes} =
               Scrubber.seed(Path.join(cache, "generic"), Path.join(tmp, "out"), trim: false)

      written = Capture.read!(Path.join([tmp, "out", "generic"]))
      assert [%Exchange{body: body}] = written.exchanges
      refute body =~ "<script"
    end

    @tag :tmp_dir
    test "a work that is a parsed category name is kept", %{tmp_dir: tmp} do
      yaml = String.replace(@yaml, "desc: Movies", "desc: Mellow Kiln")
      cache = Path.join([tmp, "cache", "harbor"])
      File.mkdir_p!(cache)
      File.write!(Path.join(cache, "definition.yml"), yaml)
      Capture.write!(capture([exchange(@page)]), Path.join(cache, "generic"))

      assert {:ok, notes} = Scrubber.seed(Path.join(cache, "generic"), Path.join(tmp, "out"))
      assert Enum.any?(notes, &(&1 =~ ~s(kept "Mellow Kiln")))
    end
  end

  defp titles(%{wasm: {:ok, results}}), do: Enum.map(results, & &1.title)
end
