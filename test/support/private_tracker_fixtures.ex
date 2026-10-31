defmodule Mydia.PrivateTrackerFixtures do
  @moduledoc """
  Three invented private trackers on Bypass, for whole-journey tests.

    * `:unit3d` (Emberline): API key as a Bearer header, JSON search, a
      download link with the rsskey in its path.
    * `:gazelle` (Vellum): form login with a CSRF token read by
      `selectorinputs`, a cookie session, HTML search, download links with
      `authkey` and `torrent_pass`.
    * `:captcha` (Harrowgate): form login with an image captcha and a 2FA code,
      posted to a separate `submitpath`.

  Each tracker keeps its live sessions in an Agent, so a test can expire them
  (`expire_sessions/1`) and watch the next search log in again. Every request
  the tracker serves is reported to the test process as
  `{:tracker, event, details}`.
  """

  alias Mydia.Indexers.CardigannDefinition
  alias Mydia.Repo

  @fixtures Path.expand("fixtures/private_trackers", __DIR__)

  @secrets %{
    apikey: "emb-api-7f3c9d2e1a4b",
    rsskey: "emb-rss-5b8e2a9c40d1",
    username: "lantern_keeper",
    password: "pw-quiet-harbor-91",
    csrf: "vel-csrf-6a1f3e",
    authkey: "vel-auth-2d6f8b1e",
    passkey: "vel-pass-91c4e7aa03f2",
    captcha: "K7QX",
    twofa: "481516",
    harrow_passkey: "har-pass-c03b77e1d9"
  }

  # A complete 1x1 PNG, so the captcha the login modal shows is a real image.
  @captcha_png Base.decode64!(
                 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
               )

  @doc "The captcha image the captcha tracker serves."
  def captcha_png, do: @captcha_png

  @files %{unit3d: "emberline-api.yml", gazelle: "vellum.yml", captcha: "harrowgate.yml"}

  @doc "The credentials and keys the invented trackers accept."
  def secrets, do: @secrets

  @doc "Every secret value, for asserting none of them leaked."
  def secret_values, do: Map.values(@secrets) -- [@secrets.username, @secrets.captcha]

  @doc """
  Starts the tracker of `kind` on `bypass` and inserts its definition with
  `config` as the stored settings. Returns `%{definition, base, agent, kind}`.
  """
  def start_tracker(bypass, kind, config \\ %{}, attrs \\ %{}) do
    base = "http://localhost:#{bypass.port}"
    {:ok, agent} = Agent.start_link(fn -> %{sessions: MapSet.new(), next: 1} end)
    test_pid = self()
    ctx = %{agent: agent, base: base, test_pid: test_pid}

    case kind do
      :unit3d -> stub_unit3d(bypass, ctx)
      :gazelle -> stub_gazelle(bypass, ctx)
      :captcha -> stub_captcha(bypass, ctx)
    end

    %{definition: insert!(kind, base, config, attrs), base: base, agent: agent, kind: kind}
  end

  @doc "The tracker forgets every session it handed out."
  def expire_sessions(%{agent: agent}),
    do: Agent.update(agent, &%{&1 | sessions: MapSet.new()})

  @doc "Inserts the invented definition of `kind`, its links pointed at `base`."
  def insert!(kind, base, config \\ %{}, attrs \\ %{}) do
    yaml =
      @fixtures
      |> Path.join(Map.fetch!(@files, kind))
      |> File.read!()
      |> String.replace(~r{https://[a-z]+\.invalid/}, base <> "/")

    {:ok, parsed} = Mydia.Indexers.CardigannParser.parse_definition(yaml)

    %CardigannDefinition{}
    |> CardigannDefinition.changeset(
      Map.merge(
        %{
          indexer_id: parsed.id,
          name: parsed.name,
          description: parsed.description,
          language: "en-US",
          type: "private",
          encoding: "UTF-8",
          links: %{"0" => base <> "/"},
          capabilities: %{},
          definition: yaml,
          schema_version: "v11",
          enabled: true,
          in_library: true,
          config: config,
          last_synced_at: DateTime.utc_now()
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  @doc "A private `.torrent` whose announce URL carries `passkey`."
  def private_torrent(passkey) do
    announce = "http://announce.invalid/#{passkey}/announce"

    "d8:announce#{byte_size(announce)}:#{announce}" <>
      "4:infod6:lengthi5e4:name5:a.mkv12:piece lengthi16384e" <>
      "6:pieces20:AAAAAAAAAAAAAAAAAAAA7:privatei1eee"
  end

  # ── Emberline (UNIT3D) ────────────────────────────────────────────────────

  defp stub_unit3d(bypass, ctx) do
    Bypass.stub(bypass, "GET", "/api/torrents", fn conn ->
      report(ctx, :login, %{authorization: header(conn, "authorization")})

      if bearer_ok?(conn),
        do: json(conn, %{data: []}),
        else: redirect(conn, "/login")
    end)

    Bypass.stub(bypass, "GET", "/login", fn conn ->
      html(conn, ~s(<a href="/login">Log in</a>))
    end)

    Bypass.stub(bypass, "GET", "/api/torrents/filter", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      report(ctx, :search, %{authorization: header(conn, "authorization"), query: conn.params})

      if bearer_ok?(conn),
        do: json(conn, unit3d_results(ctx.base)),
        else: redirect(conn, "/login")
    end)

    download_path = "/torrent/download/101.#{@secrets.rsskey}"

    for method <- ["GET", "HEAD"] do
      Bypass.stub(bypass, method, download_path, fn conn ->
        report(ctx, :download, %{method: conn.method, cookie: header(conn, "cookie")})
        torrent(conn, @secrets.passkey)
      end)
    end
  end

  defp bearer_ok?(conn), do: header(conn, "authorization") == "Bearer " <> @secrets.apikey

  defp unit3d_results(base) do
    %{
      data: [
        %{
          type: "torrent",
          id: "101",
          attributes: %{
            name: "Fictional.Harbor.Lights.2031.1080p.BluRay.x264-INVENTED",
            category_id: 1,
            size: 8_589_934_592,
            seeders: 42,
            leechers: 3,
            times_completed: 120,
            created_at: "2026-10-01T12:00:00.000000Z",
            details_link: base <> "/torrents/101",
            download_link: base <> "/torrent/download/101." <> @secrets.rsskey
          }
        }
      ]
    }
  end

  # ── Vellum (Gazelle) ──────────────────────────────────────────────────────

  defp stub_gazelle(bypass, ctx) do
    Bypass.stub(bypass, "GET", "/login.php", fn conn ->
      report(ctx, :login_page, %{})

      conn
      |> Plug.Conn.put_resp_header("set-cookie", "PHPSESSID=vel-landing; path=/")
      |> html(gazelle_login_page())
    end)

    Bypass.stub(bypass, "POST", "/login.php", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)
      report(ctx, :login, params)

      if params["auth"] == @secrets.csrf and params["username"] == @secrets.username and
           params["password"] == @secrets.password do
        sid = new_session(ctx)

        conn
        |> Plug.Conn.put_resp_header("set-cookie", "session=#{sid}; path=/; HttpOnly")
        |> redirect("index.php")
      else
        html(
          conn,
          gazelle_login_page(
            ~s(<span class="warning">Your username or password was incorrect.</span>)
          )
        )
      end
    end)

    Bypass.stub(bypass, "GET", "/index.php", fn conn ->
      if session?(ctx, conn, "session"),
        do: html(conn, ~s(<a href="logout.php?auth=x">Logout</a>)),
        else: redirect(conn, "login.php")
    end)

    for method <- ["GET", "HEAD"] do
      Bypass.stub(bypass, method, "/torrents.php", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        gazelle_torrents(conn, ctx)
      end)
    end
  end

  defp gazelle_torrents(%{params: %{"action" => "download"} = params} = conn, ctx) do
    report(ctx, :download, %{method: conn.method, params: params, cookie: header(conn, "cookie")})

    if params["id"] == "201" and params["torrent_pass"] == @secrets.passkey and
         params["authkey"] == @secrets.authkey,
       do: torrent(conn, @secrets.passkey),
       else: Plug.Conn.resp(conn, 403, "bad passkey")
  end

  defp gazelle_torrents(conn, ctx) do
    report(ctx, :search, %{params: conn.params, cookie: header(conn, "cookie")})

    if session?(ctx, conn, "session"),
      do: html(conn, gazelle_results()),
      else: redirect(conn, "login.php")
  end

  defp gazelle_login_page(extra \\ "") do
    """
    <html><head><meta name="csrf-token" content="#{@secrets.csrf}"></head><body>
    <form id="loginform" method="post" action="login.php">
      #{extra}
      <input type="text" name="username">
      <input type="password" name="password">
      <input type="checkbox" name="keeplogged" value="1">
      <input type="submit" name="login" value="Log in">
    </form></body></html>
    """
  end

  defp gazelle_results do
    dl =
      "torrents.php?action=download&amp;id=201&amp;authkey=#{@secrets.authkey}" <>
        "&amp;torrent_pass=#{@secrets.passkey}"

    """
    <html><body><a href="logout.php?auth=x">Logout</a>
    <table id="torrent_table"><tbody>
      <tr class="colhead"><td>Name</td></tr>
      <tr class="torrent">
        <td class="cat">1</td>
        <td><a href="#{dl}">DL</a> <a href="torrents.php?id=201&amp;torrentid=201">Fictional.Quiet.Orchard.2030.2160p.WEB-DL.DDP5.1-INVENTED</a>
          <strong class="freeleech">Freeleech!</strong></td>
        <td class="size">14.2 GB</td>
        <td class="snatches">57</td>
        <td class="seeders">31</td>
        <td class="leechers">2</td>
      </tr>
    </tbody></table></body></html>
    """
  end

  # ── Harrowgate (captcha + 2FA) ────────────────────────────────────────────

  defp stub_captcha(bypass, ctx) do
    Bypass.stub(bypass, "GET", "/login.php", fn conn ->
      report(ctx, :login_page, %{})

      conn
      |> Plug.Conn.put_resp_header("set-cookie", "PHPSESSID=har-landing; path=/")
      |> html("""
      <html><body><form id="login" method="post" action="login.php?unused=1">
        <input type="hidden" name="imagehash" value="hash-9a8b">
        <input type="text" name="username">
        <input type="password" name="password">
        <input type="text" name="imagestring">
        <input type="text" name="two_step_code">
        <img alt="CAPTCHA" src="image.php?action=regimage&amp;imagehash=hash-9a8b">
      </form></body></html>
      """)
    end)

    Bypass.stub(bypass, "GET", "/image.php", fn conn ->
      report(ctx, :captcha_image, %{cookie: header(conn, "cookie")})

      conn
      |> Plug.Conn.put_resp_content_type("image/png", nil)
      |> Plug.Conn.resp(200, @captcha_png)
    end)

    Bypass.stub(bypass, "POST", "/takelogin.php", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)
      report(ctx, :login, Map.put(params, "cookie", header(conn, "cookie")))

      ok? =
        params["imagestring"] == @secrets.captcha and params["two_step_code"] == @secrets.twofa and
          params["imagehash"] == "hash-9a8b" and params["username"] == @secrets.username and
          params["password"] == @secrets.password and
          String.contains?(header(conn, "cookie") || "", "PHPSESSID=har-landing")

      if ok? do
        sid = new_session(ctx)

        conn
        |> Plug.Conn.put_resp_header("set-cookie", "c_secure_uid=#{sid}; path=/")
        |> redirect("index.php")
      else
        html(
          conn,
          ~s(<table><tr><td class="embedded"><h2 class="failed">Login failed!</h2></td></tr></table>)
        )
      end
    end)

    Bypass.stub(bypass, "GET", "/index.php", fn conn ->
      if session?(ctx, conn, "c_secure_uid"),
        do: html(conn, ~s(<a href="logout.php">Logout</a>)),
        else: redirect(conn, "login.php")
    end)

    Bypass.stub(bypass, "GET", "/torrents.php", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      report(ctx, :search, %{params: conn.params, cookie: header(conn, "cookie")})

      if session?(ctx, conn, "c_secure_uid"),
        do: html(conn, harrowgate_results()),
        else: redirect(conn, "login.php")
    end)

    for method <- ["GET", "HEAD"] do
      Bypass.stub(bypass, method, "/download.php", fn conn ->
        report(ctx, :download, %{method: conn.method, cookie: header(conn, "cookie")})

        if session?(ctx, conn, "c_secure_uid"),
          do: torrent(conn, @secrets.harrow_passkey),
          else: redirect(conn, "login.php")
      end)
    end
  end

  defp harrowgate_results do
    """
    <html><body><a href="logout.php">Logout</a>
    <table class="torrents"><tbody>
      <tr class="row">
        <td class="cat">402</td>
        <td><a href="details.php?id=301&amp;hit=1">Fictional.Salt.Meadow.S02E04.1080p.WEB-DL-INVENTED</a></td>
        <td><a href="download.php?id=301">DL</a></td>
        <td class="size">2.1 GB</td>
        <td class="seeders">18</td>
        <td class="leechers">1</td>
      </tr>
    </tbody></table></body></html>
    """
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp new_session(%{agent: agent}) do
    Agent.get_and_update(agent, fn state ->
      sid = "sid-#{state.next}"
      {sid, %{state | sessions: MapSet.put(state.sessions, sid), next: state.next + 1}}
    end)
  end

  defp session?(%{agent: agent}, conn, name) do
    conn = Plug.Conn.fetch_cookies(conn)

    case conn.req_cookies[name] do
      nil -> false
      sid -> Agent.get(agent, &MapSet.member?(&1.sessions, sid))
    end
  end

  defp report(%{test_pid: pid}, event, details), do: send(pid, {:tracker, event, details})

  defp header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp html(conn, body) do
    conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.resp(200, body)
  end

  defp json(conn, data) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(data))
  end

  defp redirect(conn, location) do
    conn |> Plug.Conn.put_resp_header("location", location) |> Plug.Conn.resp(302, "")
  end

  defp torrent(%{method: "HEAD"} = conn, _passkey) do
    conn
    |> Plug.Conn.put_resp_content_type("application/x-bittorrent", nil)
    |> Plug.Conn.resp(200, "")
  end

  defp torrent(conn, passkey) do
    conn
    |> Plug.Conn.put_resp_content_type("application/x-bittorrent", nil)
    |> Plug.Conn.resp(200, private_torrent(passkey))
  end
end
