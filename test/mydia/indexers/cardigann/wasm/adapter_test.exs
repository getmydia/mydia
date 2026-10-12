defmodule Mydia.Indexers.Cardigann.Wasm.AdapterTest do
  # Drives the wasm-backed adapter against the real guest and Bypass, with
  # definitions inserted from the invented fixtures.
  use Mydia.DataCase, async: false

  alias Mydia.Indexers.Adapter.Cardigann, as: ElixirAdapter
  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.Cardigann.Wasm.{Adapter, Artifact, Engine}
  alias Mydia.Indexers.{CardigannDefinition, CardigannSearchSession, CategoryMapping}
  alias Mydia.Indexers.SearchResult
  alias Mydia.Repo

  @moduletag :cardigann_wasm
  @moduletag timeout: 120_000
  @fixtures Path.expand("../../../../support/fixtures/cardigann_wasm", __DIR__)
  @torrent "d4:infod6:lengthi5e4:name1:a12:piece lengthi16384e6:pieces20:AAAAAAAAAAAAAAAAAAAAee"

  setup do
    unless Engine.available?() do
      flunk(
        "cardigann.wasm unavailable (#{inspect(Artifact.load())}): " <>
          "run mix mydia.cardigann_guest fetch or native/cardigann_guest/build.sh wasm"
      )
    end

    original_features = Application.get_env(:mydia, :features, [])
    Application.put_env(:mydia, :features, cardigann_enabled: true)
    Application.put_env(:mydia, :cardigann_wasm_gate_opts, allow_private_except_link_local: true)

    on_exit(fn ->
      Application.put_env(:mydia, :features, original_features)
      Application.delete_env(:mydia, :cardigann_wasm_gate_opts)
    end)

    {:ok, bypass: Bypass.open()}
  end

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  defp insert_definition(fixture_name, bypass, attrs \\ %{}) do
    yaml =
      fixture_name
      |> fixture()
      |> String.replace(~r{https://[a-z]+\.invalid/}, "http://localhost:#{bypass.port}/")

    id = fixture_name |> String.split("-") |> hd()

    {:ok, definition} =
      %CardigannDefinition{}
      |> CardigannDefinition.changeset(
        Map.merge(
          %{
            indexer_id: id,
            name: String.capitalize(id),
            language: "en-US",
            type: if(id == "quill", do: "private", else: "public"),
            encoding: "UTF-8",
            links: %{"0" => "http://localhost:#{bypass.port}/"},
            capabilities: %{},
            definition: yaml,
            schema_version: "v11",
            enabled: true,
            in_library: true,
            last_synced_at: DateTime.utc_now()
          },
          attrs
        )
      )
      |> Repo.insert()

    definition
  end

  defp config(definition, user_settings \\ %{}) do
    %{
      type: :cardigann,
      name: definition.name,
      indexer_id: definition.indexer_id,
      user_settings: user_settings
    }
  end

  defp respond(bypass, method, path, body, headers \\ []) do
    Bypass.stub(bypass, method, path, fn conn ->
      conn = Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_resp_header(c, k, v) end)
      Plug.Conn.resp(conn, 200, body)
    end)
  end

  # Stubs a private tracker: counts logins, hands out a session cookie, and
  # serves the search page.
  defp stub_quill(bypass) do
    test_pid = self()

    Bypass.stub(bypass, "GET", "/login.php", fn conn ->
      send(test_pid, :login_page)
      Plug.Conn.resp(conn, 200, fixture("quill-login-page.html"))
    end)

    Bypass.stub(bypass, "POST", "/takelogin.php", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("set-cookie", "sid=abc123; Path=/")
      |> Plug.Conn.resp(200, ~s(<a href="logout.php">logout</a>))
    end)

    Bypass.stub(bypass, "GET", "/search", fn conn ->
      cookie = Plug.Conn.get_req_header(conn, "cookie")
      send(test_pid, {:search_cookie, cookie})

      # The tracker serves the results only to a logged-in client; Prowlarr's
      # engine logs in when the page lacks the login.test selector.
      if Enum.any?(cookie, &(&1 =~ "sid=abc123")),
        do: Plug.Conn.resp(conn, 200, fixture("quill-search.html")),
        else: Plug.Conn.resp(conn, 200, "<html><body>please log in</body></html>")
    end)
  end

  defp stub_logged_out_search(bypass) do
    respond(bypass, "GET", "/search", "<html><body>please log in</body></html>")
  end

  defp watch_session_writes do
    test_pid = self()
    handler = "adapter-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:mydia, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        query = metadata[:query] || ""

        if metadata[:source] == "cardigann_search_sessions" and
             String.starts_with?(query, ["INSERT", "UPDATE"]) do
          send(test_pid, {:session_write, String.slice(query, 0, 6)})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  describe "search/3" do
    test "returns SearchResults and applies the option filters", %{bypass: b} do
      respond(b, "GET", "/search", fixture("lantern-search.html"))
      definition = insert_definition("lantern-public.yml", b)

      assert {:ok, [first, second]} = Adapter.search(config(definition), "harbor")

      assert %SearchResult{
               title: "Paper Harbor 2031 1080p WEB-DL x264",
               seeders: 42,
               size: 1_610_612_736,
               indexer: "Lantern"
             } = first

      assert second.seeders == 7

      assert {:ok, [%{seeders: 42}]} =
               Adapter.search(config(definition), "harbor", min_seeders: 10)

      assert {:ok, [%{seeders: 7}]} =
               Adapter.search(config(definition), "harbor", max_size: 1_000_000_000)

      assert {:ok, [%{seeders: 42}]} =
               Adapter.search(config(definition), "harbor", min_size: 1_000_000_000)

      assert {:ok, [_]} = Adapter.search(config(definition), "harbor", limit: 1)
    end

    test "an unknown indexer is an invalid config error, like the Elixir adapter" do
      config = %{type: :cardigann, name: "Nope", indexer_id: "nope"}

      assert {:error, %Error{type: :invalid_config}} = ElixirAdapter.search(config, "x")
      assert {:error, %Error{type: :invalid_config}} = Adapter.search(config, "x")
      assert {:error, %Error{type: :invalid_config}} = Adapter.search(%{name: "x"}, "x")
    end

    test "feature flag off returns an empty list like the Elixir adapter", %{bypass: b} do
      definition = insert_definition("lantern-public.yml", b)
      Application.put_env(:mydia, :features, cardigann_enabled: false)

      assert {:ok, []} = ElixirAdapter.search(config(definition), "harbor")
      assert {:ok, []} = Adapter.search(config(definition), "harbor")

      assert {:error, %Error{type: :invalid_config}} =
               Adapter.test_connection(config(definition))
    end
  end

  describe "sessions" do
    test "logs in, stores the session, and reuses it without logging in again", %{bypass: b} do
      stub_quill(b)
      definition = insert_definition("quill-login.yml", b)
      creds = %{"username" => "reader", "password" => "secret"}

      assert {:ok, [%SearchResult{title: "Copper Lantern Society 2030 2160p WEB-DL"}]} =
               Adapter.search(config(definition, creds), "copper")

      assert_received :login_page
      assert_received {:search_cookie, [cookie]}
      assert cookie =~ "sid=abc123"

      assert [%CardigannSearchSession{cookies: ["sid=abc123"]} = row] =
               Repo.all(CardigannSearchSession)

      assert row.cardigann_definition_id == definition.id
      assert row.expires_at == nil

      assert {:ok, [_]} = Adapter.search(config(definition, creds), "copper")
      refute_received :login_page
      assert_received {:search_cookie, [cookie]}
      assert cookie =~ "sid=abc123"
    end

    test "settings accept atom keys and the stored session is shared with the Elixir reader",
         %{bypass: b} do
      stub_quill(b)
      definition = insert_definition("quill-login.yml", b)

      assert {:ok, [_]} =
               Adapter.search(
                 config(definition, %{username: "reader", password: "secret"}),
                 "copper"
               )

      assert {:ok, %{cookies: ["sid=abc123"]}} =
               Mydia.Indexers.CardigannAuth.get_stored_session(definition.id)
    end

    test "an unchanged session is not written again, a changed one is", %{bypass: b} do
      stub_quill(b)
      definition = insert_definition("quill-login.yml", b)
      creds = %{"username" => "reader", "password" => "secret"}
      watch_session_writes()

      assert {:ok, [_]} = Adapter.search(config(definition, creds), "copper")
      assert_received {:session_write, "INSERT"}

      # The guest reports session_changed on every search (Prowlarr updates
      # cookies after every fetch), but the cookies are the same.
      assert {:ok, [_]} = Adapter.search(config(definition, creds), "copper")
      refute_received {:session_write, _}

      # An expired stored session (one the Elixir engine would also drop) is
      # replaced by a fresh login: an upsert, in place rather than a second row.
      [row] = Repo.all(CardigannSearchSession)

      row
      |> Ecto.Changeset.change(%{
        expires_at: DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      })
      |> Repo.update!()

      assert {:ok, [_]} = Adapter.search(config(definition, creds), "copper")
      assert_received {:session_write, "INSERT"}
      assert_received :login_page
      assert [%{expires_at: nil}] = Repo.all(CardigannSearchSession)
    end

    test "a needs_login definition is skipped, and a stored login clears it", %{bypass: b} do
      stub_quill(b)
      definition = insert_definition("quill-login.yml", b)

      {:ok, definition} =
        definition
        |> CardigannDefinition.health_check_changeset(%{health_status: "needs_login"})
        |> Repo.update()

      creds = %{"username" => "reader", "password" => "secret"}

      for result <- [
            ElixirAdapter.search(config(definition, creds), "copper"),
            Adapter.search(config(definition, creds), "copper"),
            Adapter.download(config(definition, creds), "http://localhost/x")
          ] do
        assert {:error, %Error{type: :login_required}} = result
      end

      assert {:error, %Error{type: :login_required}} =
               Adapter.test_connection(config(definition, creds))

      assert Repo.all(CardigannSearchSession) == []

      assert {:ok, _} = Adapter.login(config(definition, creds), nil)
      assert Repo.get!(CardigannDefinition, definition.id).health_status == "healthy"
      assert {:ok, [_]} = Adapter.search(config(definition, creds), "copper")
    end

    test "a failed login stores nothing", %{bypass: b} do
      stub_logged_out_search(b)
      respond(b, "GET", "/login.php", fixture("quill-login-page.html"))
      respond(b, "POST", "/takelogin.php", ~s(<div class="error">Bad password</div>))
      definition = insert_definition("quill-login.yml", b)
      creds = %{"username" => "reader", "password" => "wrong"}

      # Prowlarr's search swallows a failed login into an empty result set; the
      # explicit login call is where the error surfaces.
      assert {:ok, []} = Adapter.search(config(definition, creds), "copper")

      assert {:error, %Error{type: :authentication_failed}} =
               Adapter.login(config(definition, creds), nil)

      assert Repo.all(CardigannSearchSession) == []
    end
  end

  describe "login/2" do
    test "stores the session it logs in", %{bypass: b} do
      stub_quill(b)
      definition = insert_definition("quill-login.yml", b)
      creds = %{"username" => "reader", "password" => "secret"}

      assert {:ok, %{cookies: %{"sid" => "abc123"}}} =
               Adapter.login(config(definition, creds), nil)

      assert [%{cookies: ["sid=abc123"]}] = Repo.all(CardigannSearchSession)
    end

    test "returns the captcha challenge, then logs in with the answer", %{bypass: b} do
      Bypass.stub(b, "GET", "/login.php", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("set-cookie", "sid=pre1; Path=/")
        |> Plug.Conn.resp(200, fixture("quill-captcha-page.html"))
      end)

      Bypass.stub(b, "GET", "/captcha.png", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "image/png")
        |> Plug.Conn.resp(200, <<1, 2, 3>>)
      end)

      test_pid = self()

      Bypass.stub(b, "POST", "/takelogin.php", fn conn ->
        {:ok, form, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:post, form})

        conn
        |> Plug.Conn.put_resp_header("set-cookie", "sid=post2; Path=/")
        |> Plug.Conn.resp(200, ~s(<a href="logout.php">logout</a>))
      end)

      definition = insert_definition("quill-captcha.yml", b, %{indexer_id: "quillcaptcha"})
      creds = %{"username" => "reader", "password" => "secret"}

      assert {:captcha, %{image: <<1, 2, 3>>, content_type: "image/png", state: state}} =
               Adapter.login(config(definition, creds), nil)

      assert Repo.all(CardigannSearchSession) == []

      assert {:ok, %{cookies: %{"sid" => "post2"}}} =
               Adapter.login(config(definition, creds), %{answer: "7KQ2", state: state})

      assert_received {:post, form}
      assert form =~ "captcha=7KQ2"
      assert [%{cookies: ["sid=post2"]}] = Repo.all(CardigannSearchSession)
    end
  end

  describe "download/3" do
    test "a torrent comes back as bytes", %{bypass: b} do
      respond(b, "GET", "/dl/101.torrent", @torrent, [
        {"content-type", "application/x-bittorrent"}
      ])

      definition = insert_definition("lantern-public.yml", b)
      link = "http://localhost:#{b.port}/dl/101.torrent"

      assert {:ok, {:bytes, @torrent}} = Adapter.download(config(definition), link)
    end

    test "a redirect to a magnet comes back as a magnet", %{bypass: b} do
      magnet = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Paper+Harbor"

      Bypass.stub(b, "GET", "/dl/101.torrent", fn conn ->
        conn |> Plug.Conn.put_resp_header("location", magnet) |> Plug.Conn.resp(302, "")
      end)

      definition = insert_definition("lantern-public.yml", b)
      link = "http://localhost:#{b.port}/dl/101.torrent"

      assert {:ok, {:magnet, ^magnet}} = Adapter.download(config(definition), link)
    end
  end

  describe "test_connection/1 and get_capabilities/1" do
    test "test_connection returns the Elixir adapter's shape", %{bypass: b} do
      respond(b, "GET", "/search", fixture("lantern-search.html"))
      respond(b, "GET", "/", "<html></html>")
      definition = insert_definition("lantern-public.yml", b)

      assert {:ok, info} = Adapter.test_connection(config(definition))
      assert Map.keys(info) |> Enum.sort() == [:indexer_id, :language, :name, :type]
      assert %{name: "Lantern", indexer_id: "lantern", language: "en-US", type: "public"} = info
    end

    test "test_connection reports a failing login as an error", %{bypass: b} do
      stub_logged_out_search(b)
      respond(b, "GET", "/login.php", fixture("quill-login-page.html"))
      respond(b, "POST", "/takelogin.php", ~s(<div class="error">Bad password</div>))
      definition = insert_definition("quill-login.yml", b)
      creds = %{"username" => "reader", "password" => "wrong"}

      assert {:error, %Error{}} = Adapter.test_connection(config(definition, creds))
    end

    test "test_connection with a missing indexer_id is an invalid config" do
      assert {:error, %Error{type: :invalid_config}} = Adapter.test_connection(%{name: "x"})
    end

    test "get_capabilities has the Elixir adapter's shape and ids CategoryMapping knows",
         %{bypass: b} do
      definition = insert_definition("lantern-public.yml", b)

      assert {:ok, %{searching: searching, categories: categories}} =
               Adapter.get_capabilities(config(definition))

      assert %{search: %{available: true}, tv_search: %{available: true}} = searching
      assert %{movie_search: %{available: true}} = searching

      assert %{id: 2000, name: "Movies"} in categories
      assert Enum.all?(categories, &(is_integer(&1.id) and is_binary(&1.name)))
      assert Enum.all?(categories, &CategoryMapping.category_name(&1.id))
    end
  end

  describe "gate options" do
    test "only the localhost relaxation is taken from app env" do
      Application.put_env(:mydia, :cardigann_wasm_gate_opts,
        allow_private_except_link_local: true,
        allowed_hosts: ["evil.example"],
        anything_else: 1
      )

      assert Adapter.gate_opts() == [allow_private_except_link_local: true]
    end
  end

  describe "request delay" do
    test "mirrors CardigannSearchEngine.apply_rate_limit" do
      assert Adapter.request_delay_ms(nil) == 0
      assert Adapter.request_delay_ms(2) == 2_000
      assert Adapter.request_delay_ms(0.5) == 500
      assert Adapter.request_delay_ms(1.25) == 1_250
      assert Adapter.request_delay_ms(9.99) == 9_990
      # At 10 and above the Elixir engine already reads milliseconds.
      assert Adapter.request_delay_ms(10) == 10
      assert Adapter.request_delay_ms(250) == 250
      assert Adapter.request_delay_ms("slow") == 0
    end
  end

  describe "settings for the guest" do
    test "merges definition config with user settings, stringifies and drops blanks" do
      definition = %CardigannDefinition{
        config: %{"sort" => "seeders", "freeleech" => false, "note" => ""}
      }

      declared = ["username", "password", "sort", "freeleech"]

      user = %{
        username: "reader",
        password: "secret",
        sort: "date",
        blank: "  ",
        empty: nil,
        flag: true,
        count: 5
      }

      assert Adapter.guest_settings(definition, user, declared) == %{
               "username" => "reader",
               "password" => "secret",
               "sort" => "date",
               "freeleech" => "false",
               "flag" => "true",
               "count" => "5"
             }
    end

    test "maps cookies onto cookie only when the definition declares a cookie setting" do
      definition = %CardigannDefinition{config: %{}}
      user = %{"cookies" => ["a=1", "b=2"]}

      assert Adapter.guest_settings(definition, user, ["cookie"]) == %{"cookie" => "a=1; b=2"}
      assert Adapter.guest_settings(definition, user, ["username"]) == %{}

      assert Adapter.guest_settings(definition, %{cookies: "a=1"}, ["cookie"]) == %{
               "cookie" => "a=1"
             }
    end
  end
end
