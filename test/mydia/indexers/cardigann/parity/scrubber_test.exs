defmodule Mydia.Indexers.Cardigann.Parity.ScrubberTest do
  use Mydia.DataCase, async: false

  alias Mydia.Indexers.CardigannParser
  alias Mydia.Indexers.Cardigann.Parity.{Capture, Fictional, RequestKey, Runner, Scrubber}
  alias Mydia.Indexers.Cardigann.Parity.Capture.Exchange
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

      fake = Fictional.name("pebbleos")
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
      assert Enum.count(LazyHTML.query(doc, "tr.head")) == 0
      assert content_length(ex) == byte_size(ex.body)
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

  describe "verify/5 leak checks" do
    # No parsing to compare, so these need no engine.
    @empty %{wasm: {:ok, []}, wasm_misses: []}

    defp leaks(body, works, opts \\ []) do
      cap = capture([exchange(body, opts)])
      Scrubber.verify(@empty, @empty, works, cap, Keyword.take(opts, [:encoding]))
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

    test "finds a work in a response header" do
      ex = exchange("clean")
      ex = %{ex | headers: [{"content-disposition", "attachment; filename=Mellow.Kiln.torrent"}]}

      assert {:error, [msg]} = Scrubber.verify(@empty, @empty, ["Mellow Kiln"], capture([ex]))
      assert msg =~ "header content-disposition"
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

      assert Scrubber.verify(original, Runner.replay(renamed), works, renamed) == :ok
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

  defp titles(%{wasm: {:ok, results}}), do: Enum.map(results, & &1.title)
end
