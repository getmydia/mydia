defmodule Mydia.Indexers.Cardigann.Wasm.Adapter do
  @moduledoc """
  A counterpart to `Mydia.Indexers.Adapter.Cardigann` that runs Prowlarr's
  Cardigann engine under Wasmex (`Mydia.Indexers.Cardigann.Wasm.Engine`).

  `search/3`, `test_connection/1` and `get_capabilities/1` return the same
  shapes as the Elixir adapter. `download/3` and `login/2` have no Elixir
  adapter counterpart:

    * `download/3` returns `{:ok, {:bytes, binary}}` for a torrent file,
      `{:ok, {:magnet, url}}` for a magnet and `{:ok, {:link, url}}` otherwise.
    * `login/2` takes `nil` or a `%{answer: String.t(), state: String.t()}`
      captcha answer and returns `{:ok, session}` or
      `{:captcha, %{image: binary, content_type: String.t(), state: String.t()}}`.

  The engine's own errors come back unchanged: an unavailable engine is
  `:engine_unavailable`, never a silent fall back to the Elixir engine.
  When the Cardigann feature flag is off the adapter behaves as the Elixir one.

  ## Sessions

  The guest keeps its cookies in a session handed in and out of each call. The
  stored session is the definition's single `cardigann_search_sessions` row, read
  and written only through `CardigannAuth.get_stored_session/1` and
  `store_session/3` (`"name=value"` strings; the Elixir engine reads the same
  row). There is no fixed expiry: the row is stored with a nil expiry.
  Prowlarr updates its cookies after every fetch, so the guest reports a changed
  session on every search; the row is written only when the cookies or expiry
  differ from what was passed in (the guest's rolling expiry is ignored). A definition in `needs_login` (set by the
  Elixir engine when a login needs a person) is skipped with a `:login_required`
  error by `search/3`, `test_connection/1` and `download/3`, as the Elixir
  adapter skips it; `login/2` is exempt, and storing a session through it moves
  the definition back to healthy.

  ## Mirror failover

  Prowlarr has no mirror failover: it searches the one base URL and turns a
  failed request into an empty page. `search/3` adds the failover Mydia's Elixir
  engine has. When a search comes back empty with the guest's `request-failed`
  signal (a transport error, an HTTP status of 400 or more, a Cloudflare
  challenge), the same search is repeated against the next entry of the
  definition's `links:` (the stored `active_link` first, at most three in all).
  A mirror that answers after another failed is stored as the definition's
  `active_link`, with the Elixir engine's rule for which mirrors may be stored.
  An empty answer without the signal is "no results" and is final. Login,
  download and the connection test go to the stored `active_link` too.

  The attempts share one deadline, the caller's `:timeout` or else the indexer
  search deadline (`Mydia.Indexers.search_deadline_ms/1`) less a small margin,
  and no further mirror is started when too little of it is left.

  When every mirror ends empty with the signal, the search is an error shaped as
  the Elixir engine's HTTP failures are (`search_failed`, "Server error: HTTP 503"
  or "HTTP 403", with `details.tracker_status`), or `connection_failed` when no
  response came back at all. The guest itself returns the empty page, as
  Prowlarr does.

  ## Failed logins

  When a login fails during `search/3`, Prowlarr's engine swallows it and the
  search returns `{:ok, []}`. The Elixir adapter returns an authentication error
  instead. `login/2` is where the failure surfaces
  (`{:error, %Error{type: :authentication_failed}}`).

  A login that needs a person (an image captcha or a 2FA code, per
  `Login.needs_person?/1`) is the exception: a search that reached the login
  form, came back empty and left the cookies unchanged parks the definition in
  `needs_login`, as the built-in engine does. The Indexers page logs
  in with the built-in login code, and the session it stores is the one this
  adapter reads.

  Setting values are credentials and are never logged.
  """

  @behaviour Mydia.Indexers.Adapter

  require Logger

  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.Cardigann.{AdapterSupport, Links, Login}
  alias Mydia.Indexers.Cardigann.Login.Inputs, as: LoginInputs
  alias Mydia.Indexers.Cardigann.Parity.Seam
  alias Mydia.Indexers.Cardigann.Wasm.Engine

  alias Mydia.Indexers.{
    CardigannAuth,
    CardigannDefinition,
    CardigannFeatureFlags,
    CardigannParser
  }

  alias Mydia.Indexers.Cardigann.SessionManager

  import AdapterSupport,
    only: [apply_search_filters: 2, blank?: 1, fetch_definition: 1, setting: 2]

  # Above the 100 s host request deadline (HostHttp), so a slow tracker is a host
  # timeout, not a guest kill.
  @default_timeout_ms 120_000
  # Left unspent of the search deadline, for persisting the result and replying.
  @deadline_margin_ms 2_000
  # A mirror is not started with less than this left of the deadline.
  @min_attempt_ms 2_000
  @empty_session %{cookies: %{}, expires_at: nil}

  @impl true
  def test_connection(config) do
    if CardigannFeatureFlags.enabled?() do
      with {:ok, definition, doc} <- load(config),
           :ok <- check_login_needed(definition, doc),
           session = stored_session(definition),
           {:ok, new_session} <-
             run(
               {:test, definition.definition, mirror_settings(definition, config, doc), session},
               definition,
               config,
               doc,
               []
             ) do
        persist_session(definition, new_session, session)

        {:ok,
         %{
           name: doc["name"],
           type: doc["type"],
           language: doc["language"],
           indexer_id: doc["id"]
         }}
      end
    else
      Logger.debug("Cardigann test connection skipped - feature disabled")
      {:error, Error.invalid_config("Cardigann feature is disabled")}
    end
  end

  @impl true
  def search(config, query, opts \\ []) do
    if CardigannFeatureFlags.enabled?() do
      run_search(config, query, opts)
    else
      Logger.debug("Cardigann search skipped - feature disabled")
      {:ok, []}
    end
  end

  # `retry?` is whether a search that met a login wall may run once more on a
  # session someone stored from the Indexers page meanwhile.
  defp run_search(config, query, opts, retry? \\ true) do
    with {:ok, definition, doc} <- load(config),
         :ok <- check_login_needed(definition, doc),
         session = stored_session(definition),
         watch = definition |> parse_links() |> login_watch(definition),
         watched_opts = if(watch, do: Keyword.put(opts, :login_watch, watch), else: opts),
         {:ok, out} <-
           search_with_failover(definition, config, doc, query, session, watched_opts) do
      watch
      |> check_swallowed_login(out, definition, session)
      |> finish_search(out, definition, session, {config, query, opts, retry?})
    end
  end

  defp finish_search(:ok, out, definition, session, {_config, _query, opts, _retry?}) do
    if out.session_changed, do: persist_session(definition, out.session, session)

    {:ok,
     out.releases
     |> apply_search_filters(opts)
     |> AdapterSupport.put_definition_privacy(definition.type)}
  end

  defp finish_search(
         {:fresh_session, _},
         _out,
         _definition,
         _session,
         {config, query, opts, true}
       ),
       do: run_search(config, query, opts, false)

  defp finish_search({:fresh_session, _}, _out, definition, _session, _search),
    do: {:error, SessionManager.needs_login_error(definition.name)}

  defp finish_search({:error, _} = error, _out, _definition, _session, _search), do: error

  # ── Logins that need a person ─────────────────────────────────────────────

  # Prowlarr's search logs in by itself and swallows a failed login into an
  # empty page. For a login that needs a person (an image captcha, a one-time
  # 2FA code), a search that reached the login form, came back empty and left
  # the cookies as they were means the login stopped at the captcha or the
  # code. The definition is then parked in `needs_login`, as the built-in
  # engine parks it, and a person logs in from the Indexers page. A login that
  # went through changes the cookies, so an honest empty result is not parked.
  defp check_swallowed_login(%{hit: hit}, %{releases: []} = out, definition, session) do
    if :atomics.get(hit, 1) == 1 and out.session.cookies == session.cookies do
      Logger.info(
        "Cardigann #{definition.indexer_id}: the login stopped for a captcha or 2FA code"
      )

      invalidate_rejected(definition, session.cookies)

      # A session stored meanwhile from the Indexers page: run_search retries on it
      # rather than report this search's empty page as "no results".
      with {:ok, user_config} <- SessionManager.park(definition),
           do: {:fresh_session, user_config}
    else
      :ok
    end
  end

  defp check_swallowed_login(_watch, _out, _definition, _session), do: :ok

  # Deletes the stored session only while it is still the one the search sent;
  # a session stored meanwhile from the Indexers page survives (and then
  # `SessionManager.park/1` does not leave the definition parked).
  defp invalidate_rejected(definition, rejected) do
    with {:ok, %{cookies: stored}} <- CardigannAuth.get_stored_session(definition.id),
         true <- cookies_to_map(stored) == rejected do
      CardigannAuth.invalidate_session(definition.id, stored)
    end
  end

  # Every URL the login form can be fetched or posted at: `login.path` and
  # `login.submitpath`, rendered with the stored settings, on each of the
  # definition's current links. HostHttp flags a request to one of them.
  defp login_watch(nil, _definition), do: nil

  defp login_watch(parsed, definition) do
    if Login.needs_person?(parsed) do
      context = LoginInputs.context(parsed, definition.config || %{})

      bases =
        [definition.active_link | Links.current(parsed)]
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim_trailing(&1, "/"))
        |> Enum.uniq()

      targets =
        for template <- [parsed.login.path, parsed.login.submitpath],
            {:ok, path} <- [LoginInputs.render(template, context)],
            path != "",
            base <- bases,
            uri = URI.parse(LoginInputs.resolve(base, path)),
            uniq: true,
            do: %{uri | query: nil, fragment: nil}

      if targets != [], do: %{targets: targets, hit: :atomics.new(1, [])}
    end
  end

  @impl true
  def get_capabilities(config) do
    with {:ok, definition, doc} <- load(config),
         {:ok, caps} <- run({:capabilities, definition.definition}, definition, config, doc, []) do
      {:ok, build_capabilities(caps)}
    end
  end

  @doc """
  Resolves a release's download link through the definition. See the moduledoc
  for the return shapes.
  """
  @spec download(map(), String.t(), keyword()) ::
          {:ok, {:bytes, binary()} | {:magnet, String.t()} | {:link, String.t()}}
          | {:error, Error.t()}
  def download(config, link, opts \\ []) do
    if CardigannFeatureFlags.enabled?() do
      with {:ok, definition, doc} <- load(config),
           :ok <- check_login_needed(definition, doc),
           session = stored_session(definition),
           call =
             {:download, definition.definition, mirror_settings(definition, config, doc), link,
              session},
           {:ok, out} <- run(call, definition, config, doc, opts) do
        persist_session(definition, out.session, session)
        {:ok, download_payload(out.payload)}
      end
    else
      {:error, Error.invalid_config("Cardigann feature is disabled")}
    end
  end

  @doc """
  Logs in and stores the session. `captcha_answer` is `nil` for the first
  attempt, or the answer to a challenge this function returned earlier.
  """
  @spec login(map(), %{answer: String.t(), state: String.t()} | nil, keyword()) ::
          {:ok, map()}
          | {:captcha, %{image: binary(), content_type: String.t(), state: String.t()}}
          | {:error, Error.t()}
  def login(config, captcha_answer, opts \\ []) do
    if CardigannFeatureFlags.enabled?() do
      run_login(config, captcha_answer, opts)
    else
      {:error, Error.invalid_config("Cardigann feature is disabled")}
    end
  end

  defp run_login(config, captcha_answer, opts) do
    with {:ok, definition, doc} <- load(config),
         call =
           {:login, definition.definition, mirror_settings(definition, config, doc),
            @empty_session, normalize_answer(captcha_answer)},
         {:ok, result} <- run(call, definition, config, doc, opts) do
      case result do
        {:ok, session} ->
          persist_session(definition, session, @empty_session)
          {:ok, session}

        {:captcha, _challenge} = captcha ->
          captcha
      end
    end
  end

  # ── Mirror failover ───────────────────────────────────────────────────────

  # Prowlarr's engine searches one base URL and, when a request fails, returns an
  # empty page. Mydia's Elixir engine moves on to the definition's next mirror, so
  # this does too: on a failed search the same call is repeated against the next
  # entry of `links:` (at most three tried, the definition's sticky `active_link`
  # first), and a mirror that answers after another failed becomes the new
  # `active_link`, as `AdapterSupport.promote_active_link/3` does for the Elixir
  # engine. `legacylinks` are not tried: the guest rewrites a legacy base URL back
  # to the first link, so they would repeat the first attempt.
  defp search_with_failover(definition, config, doc, query, session, opts) do
    settings = guest_settings(definition, config, doc)
    guest_query = build_query(query, opts)
    parsed = parse_links(definition)
    deadline = System.monotonic_time(:millisecond) + search_budget_ms(opts)

    attempt = fn base_url ->
      remaining = max(deadline - System.monotonic_time(:millisecond), 1)
      # Only the answering mirror's requests decide whether the login was reached.
      with %{hit: hit} <- opts[:login_watch], do: :atomics.put(hit, 1, 0)

      call =
        {:search, definition.definition, put_base_url(settings, base_url), guest_query, session}

      run(call, definition, config, doc, Keyword.put(opts, :timeout, remaining))
    end

    result =
      case mirror_candidates(parsed, definition) do
        [] ->
          attempt.(nil)

        [first | _] = candidates ->
          try_mirrors(
            candidates,
            attempt,
            deadline,
            &promote_winner(&1, first, parsed, definition)
          )
      end

    surface_failure(result)
  end

  defp promote_winner(winner, first, parsed, definition) do
    if winner != first, do: AdapterSupport.promote_active_link(parsed, definition, winner)
  end

  # The last mirror's answer stands when every mirror failed, as the Elixir
  # engine returns its last error. Only a search that succeeded (an answer without
  # the failed-request signal) promotes its mirror, never an error such as a
  # failed login.
  defp try_mirrors([candidate | rest], attempt, deadline, on_win) do
    result = attempt.(candidate)

    cond do
      not failed_search?(result) ->
        if match?({:ok, _}, result), do: on_win.(candidate)
        result

      rest == [] ->
        result

      deadline - System.monotonic_time(:millisecond) < @min_attempt_ms ->
        Logger.info("Cardigann search failed on #{candidate}, no time left for another mirror")
        result

      true ->
        Logger.info("Cardigann search failed on #{candidate}, trying the next mirror")
        try_mirrors(rest, attempt, deadline, on_win)
    end
  end

  # The budget for all attempts together: an explicit `:timeout`, else what the
  # indexer search task is allowed (it is killed at that deadline) less a margin.
  defp search_budget_ms(opts) do
    case Keyword.get(opts, :timeout) do
      timeout when is_integer(timeout) and timeout > 0 ->
        timeout

      _ ->
        max(Mydia.Indexers.search_deadline_ms(opts) - @deadline_margin_ms, @min_attempt_ms)
    end
  end

  # An empty answer that came with a failed request (a block, a dead mirror, a
  # transport error).
  defp failed_search?({:ok, %{releases: [], request_failed: true}}), do: true
  defp failed_search?({:error, %Error{details: %{cloudflare: true}}}), do: true
  defp failed_search?(_result), do: false

  # Where every attempt ended empty and failed, the search is an error shaped like
  # the Elixir engine's HTTP failures, so the UI and the health tracking treat
  # both engines alike. The guest returns the empty page; this is presentation.
  defp surface_failure({:ok, %{releases: [], request_failed: true} = out}),
    do: {:error, failure_error(out.failed_status)}

  defp surface_failure(result), do: result

  defp failure_error(nil),
    do: Error.connection_failed("No answer from the tracker", %{request_failed: true})

  defp failure_error(status) when status >= 500,
    do: Error.search_failed("Server error: HTTP #{status}", %{tracker_status: status})

  defp failure_error(status),
    do: Error.search_failed("HTTP #{status}", %{tracker_status: status})

  defp parse_links(%CardigannDefinition{definition: yaml}) do
    case CardigannParser.parse_definition(yaml || "") do
      {:ok, parsed} -> parsed
      {:error, _reason} -> nil
    end
  end

  defp mirror_candidates(nil, _definition), do: []

  defp mirror_candidates(parsed, definition) do
    AdapterSupport.search_candidates(parsed, active_mirror(parsed, definition), legacy: false)
  end

  # Login, download and the connection test use the mirror search settled on.
  defp mirror_settings(definition, config, doc) do
    settings = guest_settings(definition, config, doc)

    case parse_links(definition) do
      nil -> settings
      parsed -> put_base_url(settings, active_mirror(parsed, definition))
    end
  end

  defp active_mirror(parsed, %CardigannDefinition{active_link: active}) when is_binary(active) do
    active = String.trim_trailing(active, "/")
    if active in Links.current(parsed), do: active
  end

  defp active_mirror(_parsed, _definition), do: nil

  defp put_base_url(settings, nil), do: settings

  # With the trailing slash the definition's own links carry: Prowlarr resolves
  # the search path against it, which drops the last segment of a link that has a
  # path and no slash.
  defp put_base_url(settings, base_url), do: Map.put(settings, "baseUrl", base_url <> "/")

  # ── Definition and settings ───────────────────────────────────────────────

  defp load(config) do
    with {:ok, definition} <- fetch_definition(config),
         {:ok, doc} <- parse_yaml(definition) do
      {:ok, definition, doc}
    end
  end

  defp parse_yaml(%CardigannDefinition{definition: yaml}) do
    case YamlElixir.read_from_string(yaml || "") do
      {:ok, %{} = doc} ->
        {:ok, doc}

      {:ok, _not_a_map} ->
        Logger.error("Failed to parse Cardigann definition: not a YAML mapping")
        {:error, Error.search_failed("Invalid definition")}

      {:error, %{__exception__: true} = e} ->
        Logger.error("Failed to parse Cardigann definition: #{Exception.message(e)}")
        {:error, Error.search_failed("Invalid definition")}
    end
  end

  @doc false
  # Settings for the guest from the adapter config (its `user_settings` over the
  # definition's stored config), or from a bare user-settings map.
  def guest_settings(definition, %{} = config, doc) when is_map(doc) do
    guest_settings(definition, setting(config, :user_settings) || %{}, declared_settings(doc))
  end

  def guest_settings(%CardigannDefinition{} = definition, user_settings, declared)
      when is_list(declared) do
    stored = stringify_keys(definition.config || %{})

    stored
    |> Map.merge(stringify_keys(user_settings || %{}))
    |> Map.reject(fn {_name, value} -> blank?(value) end)
    |> map_cookies(declared)
    |> Map.new(fn {name, value} -> {name, stringify(value)} end)
  end

  # The Elixir adapter's `cookies` setting is Prowlarr's `cookie` setting, but
  # only a definition that declares one has anywhere to put it.
  defp map_cookies(settings, declared) do
    cond do
      "cookies" in declared ->
        settings

      "cookie" in declared ->
        {cookies, rest} = Map.pop(settings, "cookies")
        if blank?(cookies), do: rest, else: Map.put_new(rest, "cookie", stringify(cookies))

      true ->
        Map.delete(settings, "cookies")
    end
  end

  defp declared_settings(doc) do
    doc
    |> Map.get("settings")
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"name" => name} when is_binary(name) -> [name]
      _ -> []
    end)
  end

  defp stringify_keys(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_list(value), do: Enum.map_join(value, "; ", &stringify/1)
  defp stringify(value) when is_map(value), do: Jason.encode!(value)
  defp stringify(value), do: to_string(value)

  # ── Engine call ───────────────────────────────────────────────────────────

  defp run(call, definition, config, doc, opts) do
    Engine.call(
      call,
      definition |> ctx(config, doc) |> put_login_watch(opts[:login_watch]),
      Keyword.get(opts, :timeout, @default_timeout_ms)
    )
  end

  defp put_login_watch(ctx, nil), do: ctx
  defp put_login_watch(ctx, watch), do: Map.put(ctx, :login_watch, watch)

  defp ctx(definition, config, doc) do
    %{
      definition_id: definition.id,
      request_delay_ms: request_delay_ms(doc["requestDelay"] || doc["requestdelay"]),
      flaresolverr: AdapterSupport.build_flaresolverr_opts(definition),
      indexer_name: setting(config, :name) || definition.name,
      gate_opts: gate_opts()
    }
    |> Map.merge(Map.take(Seam.current() || %{}, [:replay, :record]))
  end

  @doc false
  # Test seam so Bypass on localhost passes the SSRF gate. HostHttp merges these
  # over the gate defaults, so outside the test env they are ignored, and even
  # there only the one relaxation the tests need is taken.
  # Chosen at compile time, so a release has no code path that reads them.
  @spec gate_opts() :: keyword()
  if Application.compile_env(:mydia, :env) == :test do
    def gate_opts do
      :mydia
      |> Application.get_env(:cardigann_wasm_gate_opts, [])
      |> Keyword.take([:allow_private_except_link_local])
    end
  else
    def gate_opts, do: []
  end

  @doc """
  The YAML `requestDelay` in milliseconds, normalised exactly as
  `CardigannSearchEngine.apply_rate_limit/1` does: below 10 it is seconds
  (possibly fractional), from 10 up it already is milliseconds.
  """
  @spec request_delay_ms(term()) :: non_neg_integer()
  def request_delay_ms(delay) when is_number(delay) and delay < 10, do: trunc(delay * 1000)
  def request_delay_ms(delay) when is_number(delay), do: trunc(delay)
  def request_delay_ms(_none), do: 0

  defp build_query(term, opts) do
    season = Keyword.get(opts, :season)
    episode = Keyword.get(opts, :episode)
    imdb_id = Keyword.get(opts, :imdb_id)
    tmdb_id = Keyword.get(opts, :tmdb_id)

    kind =
      cond do
        season || episode -> :tv
        imdb_id || tmdb_id -> :movie
        true -> :search
      end

    %{
      kind: kind,
      term: term,
      categories: Keyword.get(opts, :categories, []),
      imdb_id: imdb_id,
      tmdb_id: tmdb_id,
      tvdb_id: Keyword.get(opts, :tvdb_id),
      season: season,
      episode: episode && to_string(episode),
      limit: nil,
      offset: nil
    }
  end

  defp normalize_answer(nil), do: nil

  defp normalize_answer(%{} = answer),
    do: %{answer: setting(answer, :answer), state: setting(answer, :state)}

  defp download_payload({:bytes, _} = bytes), do: bytes
  defp download_payload({:link, "magnet:" <> _ = magnet}), do: {:magnet, magnet}
  defp download_payload({:link, _} = link), do: link

  defp build_capabilities(caps) do
    %{
      searching: %{
        search: %{available: Map.get(caps, "SearchAvailable", true), supported_params: ["q"]},
        tv_search: %{
          available: Map.get(caps, "TvSearchAvailable", false),
          supported_params: ["q", "season", "ep"]
        },
        movie_search: %{
          available: Map.get(caps, "MovieSearchAvailable", false),
          supported_params: ["q", "imdbid", "tmdbid"]
        }
      },
      categories:
        caps
        |> Map.get("Categories", [])
        |> Enum.map(&%{id: &1["Id"], name: &1["Name"]})
        |> Enum.filter(&is_integer(&1.id))
    }
  end

  # ── Session persistence ───────────────────────────────────────────────────

  # The stored session as the guest's session type. A missing or expired row is
  # an empty session, which makes the guest log in.
  defp stored_session(%CardigannDefinition{id: id}) do
    case CardigannAuth.get_stored_session(id) do
      {:ok, %{cookies: cookies, expires_at: expires_at}} ->
        %{cookies: cookies_to_map(cookies), expires_at: expires_at}

      {:error, _not_found_or_expired} ->
        @empty_session
    end
  end

  defp cookies_to_map(cookies) do
    for cookie when is_binary(cookie) <- List.wrap(cookies),
        [name, value] <- [String.split(cookie, "=", parts: 2)],
        into: %{},
        do: {String.trim(name), value}
  end

  defp persist_session(definition, new, passed_in) do
    if session_changed?(new, passed_in) do
      write_session(definition, new)
    else
      :ok
    end
  rescue
    e ->
      Logger.warning("Could not store Cardigann session: #{Exception.message(e)}")
      :ok
  end

  # Only the cookies count. Prowlarr hands back a rolling expiry (now plus its
  # default lifetime) on every fetch, so comparing expiries would rewrite the row
  # on every search; and Mydia keeps no fixed expiry, so none is stored.
  defp session_changed?(%{cookies: new_cookies}, %{cookies: old_cookies}),
    do: new_cookies != old_cookies

  defp write_session(_definition, %{cookies: cookies}) when map_size(cookies) == 0, do: :ok

  # One row per definition, no fixed expiry: `store_session/3` upserts with a nil
  # expiry, so the session lives until the tracker stops honoring it. A definition waiting on a
  # person (`needs_login`) is moved back to healthy, as `SessionManager.store/2`
  # does for the Elixir engine.
  defp write_session(definition, %{cookies: cookies}) do
    pairs = cookies |> Enum.sort() |> Enum.map(fn {name, value} -> "#{name}=#{value}" end)

    case CardigannAuth.store_session(definition.id, pairs, nil) do
      {:ok, _row} ->
        SessionManager.clear_needs_login(definition)

      {:error, _changeset} ->
        Logger.warning("Cardigann #{definition.indexer_id}: could not save the login session")
        :ok
    end
  end

  # Same gate the Elixir engine applies in `SessionManager.user_config/2`: a
  # definition with a login block that is waiting on a person is skipped, not
  # searched anonymously.
  defp check_login_needed(%CardigannDefinition{health_status: "needs_login"} = definition, doc) do
    if is_map(doc["login"]) do
      {:error,
       Error.login_required("#{definition.name} needs someone to log in from the Indexers page")}
    else
      :ok
    end
  end

  defp check_login_needed(_definition, _doc), do: :ok
end
