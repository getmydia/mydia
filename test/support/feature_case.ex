defmodule MydiaWeb.FeatureCase do
  @moduledoc """
  This module defines the test case for browser-based feature tests using Wallaby.

  Feature tests run in a real browser (headless Chrome by default) and can test
  JavaScript interactions, LiveView updates, and real-time features.

  ## Usage

      defmodule MydiaWeb.AuthFeatureTest do
        use MydiaWeb.FeatureCase, async: false

        @moduletag :feature  # Mark all tests in this module as feature tests

        @tag :feature
        test "user can login", %{session: session} do
          session
          |> visit("/auth/local/login")
          |> fill_in(Query.text_field("user[username]"), with: "admin")
          |> fill_in(Query.text_field("user[password]"), with: "password")
          |> click(Query.button("Sign in"))
          |> assert_path("/")
        end
      end

  ## Prerequisites

  Feature tests require chromedriver to be installed. The devenv environment
  (devenv.nix) provides chromium and chromedriver in-shell by default and sets
  CHROME_PATH/CHROMEDRIVER_PATH, so `./dev feature-test` works with no extra
  setup.

  For local development outside devenv:

      # macOS
      brew install chromedriver

      # Ubuntu/Debian
      sudo apt-get install chromium-chromedriver

      # Or specify a custom path in test.exs
      config :wallaby, :chromedriver, path: "/path/to/chromedriver"

  ## Running Feature Tests

  Feature tests are excluded by default to avoid requiring chromedriver for
  regular test runs. To run them:

      # Run all feature tests
      ./dev mix test --only feature

      # Run a specific feature test file
      ./dev mix test test/mydia_web/features/auth_test.exs --include feature

      # Run with visible browser (for debugging)
      WALLABY_HEADLESS=false ./dev mix test --only feature

      # Run all tests including feature tests
      ./dev mix test --include feature

  ## Helper Functions

  This module provides several helper functions:

  - `login(session, username, password)` - Login with credentials
  - `login_as_admin(session)` - Create an admin user and login
  - `login_as_user(session)` - Create a regular user and login
  - `login_as_guest(session)` - Create a guest user and login
  - `create_admin_user(attrs \\\\ %{})` - Create an admin user without logging in
  - `create_test_user(attrs \\\\ %{})` - Create a regular user without logging in
  - `create_guest_user(attrs \\\\ %{})` - Create a guest user without logging in
  - `assert_path(session, path)` - Assert current URL path
  - `assert_has_text(session, text)` - Assert page contains text
  - `wait_for_liveview(session)` - Wait for the LiveView root to be present
  - `eventually(fun, opts \\\\ [])` - Poll for state the browser cannot observe directly (e.g. a database write)
  - `eval_js(session, script, args \\\\ [])` - Run JavaScript in the browser and return its value
  - `js_click(session, selector)` - Escape hatch: click via JS. Prefer `click/2`.

  `MydiaWeb.FeatureCase.Geometry`'s `refute_covered/2`, `assert_in_viewport/2`,
  and `refute_clipped/2` are also auto-imported, via the `using` block below.

  ## Wallaby DSL Reference

  The `use Wallaby.DSL` brings in the following commonly used functions:

  - `visit(session, path)` - Navigate to a URL
  - `fill_in(session, query, with: value)` - Fill in a form field
  - `click(session, query)` - Click an element
  - `Query.text_field(name)` - Find an input by name
  - `Query.button(text)` - Find a button by text
  - `Query.css(selector)` - Find by CSS selector
  - `Query.link(text)` - Find a link by text

  See Wallaby documentation for more: https://hexdocs.pm/wallaby

  ## Notes

  - Feature tests use the Ecto sandbox with allowances for browser connections
  - The test server binds an ephemeral port; test_helper.exs resolves it and
    sets Wallaby's base_url
  - Screenshots are automatically captured on test failure to tmp/wallaby_screenshots
  - Set `async: false` since SQLite doesn't handle concurrent writes well
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use Wallaby.DSL

      import MydiaWeb.FeatureCase
      import MydiaWeb.FeatureCase.Geometry
      import Mydia.Factory

      alias MydiaWeb.Router.Helpers, as: Routes

      @endpoint MydiaWeb.Endpoint
    end
  end

  setup tags do
    # Every :feature test module sets `async: false` (SQLite can't take
    # concurrent writes), so exactly one of these setups runs at a time —
    # the Application.put_env swap warm_trending_cache/2 does internally is
    # safe here for that reason alone. DashboardLive.Index unconditionally
    # loads both trending rails on connected mount, and many feature tests
    # land there via the post-login redirect even when the test itself is
    # about something else entirely, so this is warmed for every feature
    # test rather than per file (#530). Empty results are fine: no feature
    # test asserts on trending content, confirmed by grep across
    # test/mydia_web/features/ before relying on it.
    #
    # library_picker_test.exs manages its own separate Bypass, its own
    # metadata_relay_url, and its own Cache.clear() afterwards; its `setup`
    # runs after this one (declared later in that file) and simply
    # overwrites what this warms, so there is no conflict between the two.
    Mydia.MetadataCacheHelpers.warm_trending_cache(:movie, [])
    Mydia.MetadataCacheHelpers.warm_trending_cache(:tv_show, [])

    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Mydia.Repo, shared: not tags[:async])

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
    end)

    metadata = Phoenix.Ecto.SQL.Sandbox.metadata_for(Mydia.Repo, pid)
    {:ok, session} = Wallaby.start_session(metadata: metadata)

    on_exit(fn ->
      Wallaby.end_session(session)
    end)

    {:ok, session: session}
  end

  @doc """
  Visits the login page and fills in the login form with the given credentials.
  """
  def login(session, username, password) do
    session
    |> Wallaby.Browser.visit("/auth/local/login")
    |> Wallaby.Browser.fill_in(Wallaby.Query.text_field("user[username]"), with: username)
    |> Wallaby.Browser.fill_in(Wallaby.Query.text_field("user[password]"), with: password)
    |> Wallaby.Browser.click(Wallaby.Query.button("Log In"))
  end

  @doc """
  Creates a test user and logs them in via the browser.
  Returns the session with the user logged in.
  """
  def login_as_admin(session) do
    user = create_admin_user()
    login(session, user.username, "password123")
  end

  @doc """
  Creates a regular test user and logs them in via the browser.
  Returns the session with the user logged in.
  """
  def login_as_user(session) do
    user = create_test_user()
    login(session, user.username, "password123")
  end

  @doc """
  Creates an admin user for feature tests.
  """
  def create_admin_user(attrs \\ %{}) do
    default_attrs = %{
      email: "admin-#{System.unique_integer([:positive])}@example.com",
      username: "admin#{System.unique_integer([:positive])}",
      password: "password123",
      role: "admin"
    }

    {:ok, user} =
      default_attrs
      |> Map.merge(attrs)
      |> Mydia.Accounts.create_user()

    user
  end

  @doc """
  Creates a regular user for feature tests.
  """
  def create_test_user(attrs \\ %{}) do
    default_attrs = %{
      email: "test-#{System.unique_integer([:positive])}@example.com",
      username: "testuser#{System.unique_integer([:positive])}",
      password: "password123",
      role: "user"
    }

    {:ok, user} =
      default_attrs
      |> Map.merge(attrs)
      |> Mydia.Accounts.create_user()

    user
  end

  @doc """
  Creates a guest user for feature tests.
  """
  def create_guest_user(attrs \\ %{}) do
    default_attrs = %{
      email: "guest-#{System.unique_integer([:positive])}@example.com",
      username: "guest#{System.unique_integer([:positive])}",
      password: "password123",
      role: "guest"
    }

    {:ok, user} =
      default_attrs
      |> Map.merge(attrs)
      |> Mydia.Accounts.create_user()

    user
  end

  @doc """
  Creates a guest user and logs them in via the browser.
  Returns the session with the guest user logged in.
  """
  def login_as_guest(session) do
    user = create_guest_user()
    login(session, user.username, "password123")
  end

  @doc """
  Asserts that the current path matches the expected path.
  """
  def assert_path(session, expected_path) do
    assert Wallaby.Browser.current_path(session) == expected_path
    session
  end

  @doc """
  Asserts that the page contains the given text.
  """
  def assert_has_text(session, text) do
    assert Wallaby.Browser.has_text?(session, text)
    session
  end

  @doc """
  Blocks until the root LiveView has connected its socket.

  `data-phx-main` is server-rendered and present before connect, so asserting
  on it alone proves nothing. LiveView adds `phx-connected` to the view
  container in `hideLoader()` once the join succeeds, which is the real signal.

  This polls through `eventually/2` with its own budget rather than through
  `Wallaby.Browser.find/2` and the global `:max_wait_time`, for two reasons: a
  socket join is slower than a DOM assertion and deserves a longer wait, and a
  raise from `find/2` reports only that a selector did not match, which cannot
  say whether the page had no LiveView at all or had one that never connected.

  Each poll reads the DOM through `eval_js/3` (`Wallaby.Browser.execute_script/4`),
  not `Wallaby.Browser.has?/2`. `has?/2` goes through `execute_query/2` and
  `retry/2`, which themselves poll up to the global `:max_wait_time` before
  reporting a miss, so a single failed `has?/2` call can eat that entire budget
  and make the `:timeout` option here a lower bound in name only. `execute_script`
  issues one WebDriver call and returns, so `eventually/2`'s own budget is what
  actually governs the wait.

  A WebDriver-level failure (a crashed browser session, for example) surfaces
  as a `RuntimeError` from deep inside Wallaby's HTTP client, indistinguishable
  by type from `eventually/2`'s own timeout. Only the latter's exact message is
  turned into the diagnostic below; anything else is re-raised unchanged so a
  dead session is never reported as an ordinary unconnected socket.

  Options: `:timeout` (ms, default 15_000).
  """
  def wait_for_liveview(session, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 15_000)

    try do
      eventually(
        fn ->
          if root_connected?(session) do
            {:ok, session}
          else
            :error
          end
        end,
        timeout: timeout,
        description: "the root LiveView to connect its socket"
      )
    rescue
      e in RuntimeError ->
        if String.starts_with?(e.message, "eventually/2 timed out") do
          reraise liveview_failure_message(root_present?(session), timeout), __STACKTRACE__
        else
          reraise e, __STACKTRACE__
        end
    end

    session
  end

  defp root_connected?(session) do
    eval_js(session, "return document.querySelector('[data-phx-main].phx-connected') !== null;")
  end

  defp root_present?(session) do
    eval_js(session, "return document.querySelector('[data-phx-main]') !== null;")
  end

  @doc """
  The message `wait_for_liveview/2` raises when the socket does not join.

  Public so it can be tested without a browser. `root_present?` is whether any
  `[data-phx-main]` element exists, which is what separates the two causes.
  """
  def liveview_failure_message(true, timeout_ms) do
    """
    The root LiveView rendered but its socket never joined within #{timeout_ms}ms.
    `[data-phx-main]` is present; `phx-connected` is not.

    The usual cause is a missing asset build. Without priv/static/assets/app.js
    there is no LiveView client, so the socket cannot connect. A fresh worktree
    never has one, since the asset build is per-worktree. Fix with:

        devenv shell -- bash -c 'mix assets.setup && mix assets.build'

    Then confirm the setup with:

        mix test test/mydia_web/features/smoke_test.exs --only feature

    Other causes: a JavaScript exception before LiveView boots, or a server
    crash during the join.
    """
  end

  def liveview_failure_message(false, timeout_ms) do
    """
    No root LiveView rendered within #{timeout_ms}ms: no element matches
    `[data-phx-main]`.

    The page under test is probably not the page expected. Check for a redirect,
    an unauthenticated session lands on the log-in page, or for a route that
    renders a plain controller view rather than a LiveView.
    """
  end

  @doc """
  Polls `fun` until it returns `{:ok, value}`, then returns `value`.

  For state Wallaby cannot see, principally database writes that a LiveView
  performs after the browser has already returned. `fun` returns `{:ok, value}`
  on success or `:error` to keep waiting.

  Options: `:timeout` (ms, default 10_000), `:interval` (ms, default 100),
  `:description` (used in the timeout message).

      request =
        eventually(
          fn ->
            case Repo.get_by(MediaRequest, tmdb_id: id) do
              nil -> :error
              request -> {:ok, request}
            end
          end,
          description: "a media request with tmdb_id \#{id}"
        )
  """
  def eventually(fun, opts \\ []) when is_function(fun, 0) do
    timeout = Keyword.get(opts, :timeout, 10_000)
    interval = Keyword.get(opts, :interval, 100)
    description = Keyword.get(opts, :description, "condition")
    deadline = System.monotonic_time(:millisecond) + timeout

    poll_until(fun, deadline, interval, description, timeout)
  end

  defp poll_until(fun, deadline, interval, description, timeout) do
    case fun.() do
      {:ok, value} ->
        value

      :error ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise "eventually/2 timed out after #{timeout}ms waiting for #{description}"
        else
          Process.sleep(interval)
          poll_until(fun, deadline, interval, description, timeout)
        end
    end
  end

  @doc """
  Runs `script` in the browser and returns its value.

  `Wallaby.Browser.execute_script/3` throws the return value away; the 4-arity
  form hands it to a callback, which runs synchronously in this process. So the
  value can be stashed under a unique process-dictionary key and taken straight
  back out.

  Arguments are exposed to the script as `arguments[0]`, `arguments[1]`, and so
  on. The script must `return` explicitly.

      theme = eval_js(session, "return document.documentElement.dataset.theme;")
  """
  def eval_js(session, script, args \\ []) do
    key = {__MODULE__, :eval_js, make_ref()}

    Wallaby.Browser.execute_script(session, script, args, fn value ->
      Process.put(key, value)
    end)

    Process.delete(key)
  end

  @doc """
  Escape hatch: clicks an element via JavaScript.

  Prefer `Wallaby.Browser.click/2` with a `Query`, which scrolls into view and
  retries on its own. Reach for this only when a real click genuinely cannot
  reach the element, and note why at the call site. A `phx-click` that does not
  respond to a real click is usually a UI defect worth fixing rather than
  routing around.

  This does not wait. Follow it with an assertion on the resulting DOM, which
  retries, or with `eventually/2` for database state.
  """
  def js_click(session, css_selector) do
    Wallaby.Browser.execute_script(
      session,
      """
      var el = document.querySelector(arguments[0]);
      if (el) {
        el.scrollIntoView({behavior: 'instant', block: 'center'});
        el.focus();
        el.click();
      }
      """,
      [css_selector]
    )

    session
  end
end
