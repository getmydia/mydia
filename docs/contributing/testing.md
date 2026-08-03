# Testing

Mydia uses ExUnit for unit and integration testing with comprehensive LiveView test support.

## Running Tests

### All Tests

```bash
./dev mix test
```

### Specific File

```bash
./dev mix test test/mydia/libraries_test.exs
```

### Specific Test

```bash
./dev mix test test/mydia/libraries_test.exs:42
```

### Failed Tests Only

```bash
./dev mix test --failed
```

## Test Types

### Unit Tests

Test individual modules and functions:

```elixir
defmodule Mydia.LibrariesTest do
  use Mydia.DataCase

  alias Mydia.Libraries

  describe "list_libraries/0" do
    test "returns all libraries" do
      library = library_fixture()
      assert Libraries.list_libraries() == [library]
    end
  end
end
```

### Integration Tests

Test multiple components together:

```elixir
defmodule Mydia.Downloads.PipelineTest do
  use Mydia.DataCase

  test "download pipeline processes release correctly" do
    # Setup
    movie = movie_fixture()
    release = release_fixture(movie)

    # Execute
    {:ok, download} = Downloads.start_download(release)

    # Verify
    assert download.status == :downloading
  end
end
```

### LiveView Tests

Test Phoenix LiveView components:

```elixir
defmodule MydiaWeb.LibraryLiveTest do
  use MydiaWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "index" do
    test "lists all libraries", %{conn: conn} do
      library = library_fixture()

      {:ok, view, html} = live(conn, ~p"/libraries")

      assert html =~ library.name
    end

    test "creates new library", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/libraries")

      view
      |> form("#library-form", library: %{name: "Movies"})
      |> render_submit()

      assert has_element?(view, "#library-list", "Movies")
    end
  end
end
```

## Test Helpers

### Data Case

For tests that need database access:

```elixir
use Mydia.DataCase
```

Provides:

- Database transactions (automatic rollback)
- Fixture functions
- Ecto helpers

### Conn Case

For web tests:

```elixir
use MydiaWeb.ConnCase
```

Provides:

- Connection setup
- Authentication helpers
- LiveView testing

### Fixtures

Create test data with fixtures:

```elixir
defmodule Mydia.LibrariesFixtures do
  def library_fixture(attrs \\ %{}) do
    {:ok, library} =
      attrs
      |> Enum.into(%{
        name: "Test Library",
        path: "/test/path",
        type: :movies
      })
      |> Mydia.Libraries.create_library()

    library
  end
end
```

## Test Patterns

### Testing LiveView Interactions

```elixir
test "user can search for media", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/search")

  # Fill in search form
  view
  |> element("#search-form")
  |> render_submit(%{query: "Matrix"})

  # Verify results appear
  assert has_element?(view, "#search-results")
  assert has_element?(view, ".result-item", "The Matrix")
end
```

### Testing Form Validation

```elixir
test "shows validation errors", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/libraries/new")

  view
  |> form("#library-form", library: %{name: ""})
  |> render_change()

  assert has_element?(view, ".error", "can't be blank")
end
```

### Testing Flash Messages

```elixir
test "shows success message", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/libraries")

  view
  |> form("#library-form", library: %{name: "New Library"})
  |> render_submit()

  assert render(view) =~ "Library created successfully"
end
```

## Test Configuration

### Test Database

Tests use a separate database that's automatically created and migrated.

### Async Tests

Enable async for non-database tests:

```elixir
use ExUnit.Case, async: true
```

### Tags

Skip or focus tests with tags:

```elixir
@tag :skip
test "skipped test" do
end

@tag :slow
test "slow test" do
end
```

Run with:

```bash
./dev mix test --exclude slow
./dev mix test --only slow
```

## Code Coverage

Generate coverage report:

```bash
./dev mix test --cover
```

## Best Practices

1. **Test behavior, not implementation** - Focus on what, not how
2. **One assertion per test** - When practical
3. **Clear test names** - Describe the scenario
4. **Use fixtures** - Keep setup DRY
5. **Deterministic tests** - No random failures

## Continuous Integration

Tests run automatically on:

- Pull requests
- Commits to main

CI runs:

- Code compilation (warnings as errors)
- Formatting checks
- Credo static analysis
- Full test suite
- Docker build verification

## Next Steps

- [E2E Testing](e2e-testing.md) - Browser-based testing with Playwright
- [Development Setup](setup.md) - Local environment setup
