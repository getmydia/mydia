defmodule MydiaWeb.FeatureCase do
  @moduledoc """
  This module defines the test case for browser-based feature tests using Wallaby.

  Feature tests run in a real browser (headless Chrome by default) and can test
  JavaScript interactions, LiveView updates, and real-time features.

  ## Why Wallaby over Playwright?

  - **Native Elixir integration**: Tests are written in Elixir and run with ExUnit
  - **Ecto sandbox support**: Each test runs in a database transaction, automatically rolled back
  - **Concurrent execution**: Tests can run in parallel without data conflicts
  - **No Node.js dependency**: Eliminates the need for a separate Node.js E2E test infrastructure
  - **Consistent patterns**: Same testing patterns as the rest of the codebase

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
  - `assert_path(session, path)` - Assert current URL path
  - `assert_has_text(session, text)` - Assert page contains text
  - `wait_for_liveview(session)` - Wait for LiveView to connect

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
      import Mydia.Factory

      alias MydiaWeb.Router.Helpers, as: Routes

      @endpoint MydiaWeb.Endpoint
    end
  end

  setup tags do
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
  Waits for LiveView to connect and be ready.
  Useful after navigation or form submissions.
  """
  def wait_for_liveview(session) do
    # Wait for data-phx-main which indicates LiveView root is present
    session
    |> Wallaby.Browser.find(Wallaby.Query.css("[data-phx-main]", []))
    |> then(fn _ ->
      # Wait for LiveView to connect and stabilize
      :timer.sleep(3000)
      session
    end)
  end

  @doc """
  Waits for LiveView to process an event after a button click.
  Use this after click() calls to ensure DOM updates are complete.
  """
  def wait_for_liveview_update(session) do
    :timer.sleep(500)
    session
  end

  @doc """
  Clicks an element using JavaScript. More reliable in headless browsers
  for phx-click buttons that don't respond to standard clicks.
  """
  def js_click(session, css_selector) do
    # Scroll element into view and click
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

    # Wait for LiveView to process the event and update the DOM
    :timer.sleep(2000)

    session
  end

  @doc """
  Waits for LiveView to be idle (no pending operations).
  Uses a simple delay-based approach since checking phx-loading classes
  via execute_script is unreliable (returns session, not value).
  """
  def wait_for_liveview_idle(session) do
    # Simple approach: wait a fixed amount of time for LiveView to stabilize
    # This is more reliable than trying to check for phx-loading classes
    :timer.sleep(500)
    session
  end

  @doc """
  Asserts that the page has the given text, with retry.
  More reliable than Wallaby.Browser.has_text? in CI environments.
  """
  def assert_has_text_with_retry(session, text, attempts \\ 20) do
    if attempts <= 0 do
      raise "Expected to find text '#{text}' but it was not found after retries"
    end

    if Wallaby.Browser.has_text?(session, text) do
      session
    else
      :timer.sleep(500)
      assert_has_text_with_retry(session, text, attempts - 1)
    end
  end

  @doc """
  Asserts that the page source contains the given text, with retry.
  Uses page_source instead of has_text? to avoid chromedriver log endpoint hangs.
  Useful after execute_script calls that trigger LiveView updates.
  """
  def assert_page_contains(session, text, attempts \\ 20) do
    if attempts <= 0 do
      raise "Expected page source to contain '#{text}' but it was not found after retries"
    end

    html = Wallaby.Browser.page_source(session)

    if String.contains?(html, text) do
      session
    else
      :timer.sleep(500)
      assert_page_contains(session, text, attempts - 1)
    end
  end

  @doc """
  Pushes a LiveView event by injecting a temporary hidden button with phx-click
  attributes and clicking it. More reliable than direct JS API calls because
  Phoenix LiveView automatically binds phx-click handlers on new DOM elements.
  """
  def push_liveview_event(session, event, params) do
    param_attrs =
      Enum.map_join(params, "\n", fn {k, v} -> "el.setAttribute('phx-value-#{k}', '#{v}');" end)

    Wallaby.Browser.execute_script(
      session,
      """
      var el = document.createElement('button');
      el.setAttribute('phx-click', '#{event}');
      #{param_attrs}
      el.style.display = 'none';
      var container = document.querySelector('[data-phx-main]');
      container.appendChild(el);
      el.click();
      setTimeout(function() { el.remove(); }, 100);
      """,
      []
    )

    :timer.sleep(2000)

    session
  end

  def wait_for_any_text(session, texts, attempts \\ 20) when is_list(texts) do
    if attempts <= 0 do
      false
    else
      found = Enum.any?(texts, fn text -> Wallaby.Browser.has_text?(session, text) end)

      if found do
        true
      else
        :timer.sleep(500)
        wait_for_any_text(session, texts, attempts - 1)
      end
    end
  end
end
