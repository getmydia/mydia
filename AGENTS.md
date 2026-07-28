This is a web application written using the Phoenix web framework.

## About Mydia

Mydia is a self-hosted media management application for organizing and tracking TV shows and movies. It helps users:

- Manage their personal media libraries
- Track TV show episodes and seasons
- Organize movies and their metadata
- Monitor media files and their locations
- Automatically fetch metadata from external sources

The application is designed to be deployed on personal servers or home lab environments, giving users complete control over their media collection data.

## Remote Access Architecture (P2P)

Mydia uses a decentralized **p2p** architecture for remote access.

### Key Components

- **Core (Rust)**: The shared networking logic (Host, Swarm, DHT, mDNS) is implemented in a pure Rust crate (`native/mydia_p2p_core`). This ensures protocol parity between client and server.
- **Backend (Elixir)**: The Phoenix app wraps the core crate using a Rustler NIF (`Mydia.P2p`). It acts as a permanent node in the mesh.
- **Frontend (Flutter)**: The player app wraps the same core crate using `flutter_rust_bridge`. It connects to the backend via the p2p mesh for discovery and control.

### Connectivity

- **Discovery**: Nodes find each other via mDNS (local network) and Kademlia DHT (internet).
- **Transport**: Connections are established over TCP or QUIC, secured with Noise encryption.
- **Media**: Media streams (HLS) are served over the p2p connection (via a local proxy in the client).

## Metadata Relay Service

Mydia uses a companion service called **metadata-relay**, which is a developer-owned service that:

- **Proxies metadata requests** to external services like TVDB and TMDB
- **Protects API keys** by avoiding direct client-to-service connections
- **Reduces rate limiting issues** by centralizing API requests
- **Prevents API key leakage** in client applications

### Key Points

- The metadata-relay service is **developed together with mydia** but **deployed completely separately**
- Mydia instances connect to metadata-relay instead of hitting TVDB/TMDB directly
- This architecture allows multiple mydia instances to share a single metadata-relay deployment
- The service handles authentication and rate limiting centrally

### When Working on Metadata Integration

- **Always** use the metadata-relay endpoints instead of direct TVDB/TMDB API calls
- **Never** embed TVDB or TMDB API keys directly in the mydia application
- Configure the metadata-relay base URL via application configuration
- Handle metadata-relay service failures gracefully with appropriate error messages

## Player (Flutter)

The Flutter player has additional workflow guidance in `player/CLAUDE.md`.

### Player Android Builds

Android builds use the player's Nix flake (`player/flake.nix`) which provides Flutter, Android SDK, NDK, and Rust cross-compilation toolchains.

**Commands:**

- `./dev player android build` - Build release APK
- `./dev player android run` - Build and run on connected Android device
- `./dev player android shell` - Open nix develop shell for manual commands

**Output:** `player/build/app/outputs/flutter-apk/app-release.apk`

**Requirements:** Nix must be installed on the host system (not Docker).

**What the flake provides:**
- Flutter SDK
- Android SDK with NDK 27.0.12077973
- Rust toolchain with Android targets (aarch64, armv7, x86_64, i686)
- All necessary environment variables for Rust cross-compilation

### Player macOS Builds

macOS builds use the **host** toolchain — neither devenv nor `player/flake.nix`. Xcode and CocoaPods are Apple-licensed SDKs Nix cannot provide, and cargokit shells out to `rustup` to compile the Rust p2p core into the app bundle.

**Commands:**

- `./dev player macos run` - Debug build and run on this Mac (hot reload)
- `./dev player macos build` - Release build
- Both accept `--skip-codegen` to reuse existing build_runner output; extra args after `run` pass through to `flutter run`

**Output:** `player/build/macos/Build/Products/Release/Mydia Player.app`

**Requirements:** **Full Xcode** (Command Line Tools alone cannot build app bundles), CocoaPods (`pod`), Flutter, and rustup installed on the host. `./dev` preflights all four and prints the fix for whichever is missing.

## Project guidelines

- Use `mix precommit` alias when you are done with all changes and fix any pending issues
- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps

### DRY Patterns (Don't Repeat Yourself)

**Extract repeated logic into private functions:**

    # BAD: duplicated validation logic
    def create_show(attrs) do
      if String.length(attrs["title"] || "") > 0 do
        # ...
      end
    end

    def update_show(show, attrs) do
      if String.length(attrs["title"] || "") > 0 do
        # ...
      end
    end

    # GOOD: extract to private function
    defp valid_title?(attrs), do: String.length(attrs["title"] || "") > 0

**Use `with` for sequential operations instead of nested case:**

    # BAD: deeply nested case statements
    case fetch_show(id) do
      {:ok, show} ->
        case fetch_seasons(show) do
          {:ok, seasons} ->
            case update_metadata(show, seasons) do
              {:ok, updated} -> {:ok, updated}
              {:error, reason} -> {:error, reason}
            end
          {:error, reason} -> {:error, reason}
        end
      {:error, reason} -> {:error, reason}
    end

    # GOOD: flat with statement
    with {:ok, show} <- fetch_show(id),
         {:ok, seasons} <- fetch_seasons(show),
         {:ok, updated} <- update_metadata(show, seasons) do
      {:ok, updated}
    end

**Centralize business logic in context modules:**

- **Never** duplicate query logic across LiveViews or controllers
- **Always** put queries and business logic in context modules (e.g., `Mydia.Media`, `Mydia.Libraries`)
- Create reusable query functions: `list_shows/1`, `get_show!/1`, `list_shows_with_seasons/1`

**Leverage existing components - check before creating:**

- **Always** check `core_components.ex` before creating new UI components
- **Always** use `<.input>`, `<.button>`, `<.modal>`, `<.table>` from core components
- **Never** duplicate styling - if a pattern repeats 3+ times, extract to a component

**Create shared function components for repeated UI patterns:**

    # In core_components.ex or a dedicated components module
    attr :show, :map, required: true
    def show_card(assigns) do
      ~H"""
      <div class="card bg-base-100 shadow-xl">
        <figure><img src={@show.poster_url} /></figure>
        <div class="card-body">
          <h2 class="card-title">{@show.title}</h2>
        </div>
      </div>
      """
    end

**Use module attributes for repeated values:**

    # BAD: magic strings scattered throughout
    def fetch_metadata(show) do
      Req.get("https://api.metadata-relay.example.com/shows/#{show.id}")
    end

    # GOOD: module attribute
    @metadata_relay_url Application.compile_env(:mydia, :metadata_relay_url)

    def fetch_metadata(show) do
      Req.get("#{@metadata_relay_url}/shows/#{show.id}")
    end

### Development environment

This project uses [devenv.sh](https://devenv.sh) for local development, auto-loaded per git worktree via [direnv](https://direnv.net). The daily loop runs natively (no Docker dev container); each worktree derives its own non-colliding ports and isolated state. **Always** use the `./dev` command wrapper (a thin shim over devenv) instead of running commands directly:

- **Process lifecycle**: `./dev up [-d]`, `./dev down`, `./dev restart`, `./dev logs <process>`, `./dev ps`
- **Interactive shells**: `./dev shell`, `./dev iex`, `./dev bash`
- **Mix commands**: `./dev mix <args>` (e.g., `./dev mix test`, `./dev mix ecto.migrate`)
- **Common shortcuts**: `./dev test`, `./dev format`, `./dev deps.get`, `./dev ecto.migrate`

Prerequisites: Nix, devenv, and direnv (see `docs/development/setup.md`). Run `./dev` without arguments to see all available commands.

**Examples**:

- `./dev up -d` - Start the worktree stack in the background
- `./dev test` - Run all tests (automatically sets up test database)
- `./dev mix ecto.migrate` - Run database migrations
- `./dev shell` - Open an interactive devenv shell
- `./dev logs phoenix` - Show the Phoenix process logs

### User management

- **Development**: `./dev mix mydia.user <command>` (list, add, delete, reset-password)
- **Production container**: `mydia-cli user <command>` (wraps the mix task via release eval)
- **Default dev credentials**: username `admin`, password `adminadmin`

### Git Guidelines

**Run git commands inside the devenv shell:**

Always run `git` (especially `git commit`) from inside the devenv shell — i.e. with direnv loaded in the worktree, or via `devenv shell -- git commit -m "message"`.

The pre-commit hooks (defined in `devenv.nix` under `git-hooks.hooks`) lint Rust via the pinned 1.96.0 toolchain. Running git outside the devenv environment can fail to find the toolchain on `PATH` and is not guaranteed to use the same compiler the hooks expect. devenv installs the hooks automatically on shell entry; it owns the generated `.pre-commit-config.yaml` (git-ignored).

**Working with uncommitted changes:**

Uncommitted changes from other agents or sessions are normal. Focus on your task and leave unrelated changes alone.

**Basic workflow:**

- Check status: `git status` and `git diff` to see what you're changing
- Make your changes directly to files as needed
- Stage your files: `git add <your-files>`
- Commit your work when ready
- If you need to unstage specific files: `git restore --staged <file>`

**When compilation errors occur:**

- Errors in your code → fix them
- Errors in other files → ignore them, continue with your task, another agent will handle it
- Run specific tests that work: `./dev mix test test/your_test.exs`

**Selective staging:**

To commit only some files when multiple files are staged:

```bash
# Unstage the files you don't want to commit
git restore --staged file3.ex file4.ex

# Commit the remaining staged files
git commit -m "message"
```

### Phoenix v1.8 guidelines

- **Always** begin your LiveView templates with `<Layouts.app flash={@flash} ...>` which wraps all inner content
- The `MyAppWeb.Layouts` module is aliased in the `my_app_web.ex` file, so you can use it without needing to alias it again
- Anytime you run into errors with no `current_scope` assign:
  - You failed to follow the Authenticated Routes guidelines, or you failed to pass `current_scope` to `<Layouts.app>`
  - **Always** fix the `current_scope` error by moving your routes to the proper `live_session` and ensure you pass `current_scope` as needed
- Phoenix v1.8 moved the `<.flash_group>` component to the `Layouts` module. You are **forbidden** from calling `<.flash_group>` outside of the `layouts.ex` module
- Out of the box, `core_components.ex` imports an `<.icon name="hero-x-mark" class="w-5 h-5"/>` component for for hero icons. **Always** use the `<.icon>` component for icons, **never** use `Heroicons` modules or similar
- **Always** use the imported `<.input>` component for form inputs from `core_components.ex` when available. `<.input>` is imported and using it will will save steps and prevent errors
- If you override the default input classes (`<.input class="myclass px-2 py-1 rounded-lg">)`) class with your own values, no default classes are inherited, so your
  custom classes must fully style the input

### JS and CSS guidelines

- **Use Tailwind CSS with DaisyUI** to create polished, responsive, and visually stunning interfaces.
- Tailwindcss v4 **no longer needs a tailwind.config.js** and uses a new import syntax in `app.css`:

      @import "tailwindcss" source(none);
      @source "../css";
      @source "../js";
      @source "../../lib/my_app_web";

- **Always use and maintain this import syntax** in the app.css file for projects generated with `phx.new`
- **Never** use `@apply` when writing raw css
- **Use DaisyUI 4.x components** for consistent, accessible UI elements:
  - DaisyUI provides semantic component classes (btn, card, modal, etc.)
  - Combine DaisyUI components with custom Tailwind classes for specific styling
  - Use DaisyUI's built-in theming system for dark/light modes
  - Reference: https://daisyui.com/components/
- Out of the box **only the app.js and app.css bundles are supported**
  - You cannot reference an external vendor'd script `src` or link `href` in the layouts
  - You must import the vendor deps into app.js and app.css to use them
  - **Prefer** file-based hooks in `assets/js/` for hooks longer than a few lines. Colocated JS (`<script :type={ColocatedJS}>`) is available for template-local hooks. Raw `<script>` tags without `:type={ColocatedJS}` remain discouraged.

### DaisyUI Component Guidelines

- **Always use DaisyUI semantic component classes** for UI elements:
  - Buttons: `btn`, `btn-primary`, `btn-secondary`, `btn-ghost`, `btn-sm`, etc.
  - Cards: `card`, `card-body`, `card-title`, `card-actions`
  - Modals: `modal`, `modal-box`, `modal-action`, `modal-backdrop`
  - Forms: `input`, `input-bordered`, `select`, `checkbox`, `radio`, `textarea`
  - Navigation: `menu`, `drawer`, `navbar`, `tabs`, `breadcrumbs`
  - Feedback: `alert`, `badge`, `progress`, `loading`, `toast`
  - Layout: `divider`, `collapse`, `dropdown`
- **Combine DaisyUI with Tailwind utilities** for custom spacing, colors, and responsive design:
  - Example: `<button class="btn btn-primary px-8 py-4 text-lg">Click Me</button>`
- **Use DaisyUI's size and color modifiers** consistently:
  - Sizes: `btn-xs`, `btn-sm`, `btn-md`, `btn-lg`
  - Colors: `btn-primary`, `btn-secondary`, `btn-accent`, `btn-info`, `btn-success`, `btn-warning`, `btn-error`
  - States: `btn-disabled`, `btn-loading`, `btn-ghost`, `btn-outline`
- **Leverage DaisyUI themes** for dark/light mode support:
  - Configure custom theme in tailwind config if needed
  - Use semantic color names (`primary`, `secondary`, `accent`, `base-100`, etc.)
- **Reference DaisyUI documentation** for complete component APIs and variants

### Component Organization

Components follow a three-tier system:

- `lib/mydia_web/components/core_components.ex` — Framework-level components (input, button, modal, table, icon). Always globally imported.
- `lib/mydia_web/components/<domain>_components.ex` — Shared domain components (LibraryComponents, CollectionComponents, etc.). Globally imported via `html_helpers` only if used by 3+ LiveViews.
- `lib/mydia_web/live/<feature>_live/components.ex` — LiveView-specific components. Never globally imported. Used only by the sibling LiveView.
- No component file should exceed ~500 LOC. Split by sub-domain if larger.
- When a function component needs its own `handle_event`, promote it to a LiveComponent or extract it into its own LiveView.

### UI/UX & design guidelines

- **Produce world-class UI designs** with a focus on usability, aesthetics, and modern design principles
- Implement **subtle micro-interactions** (e.g., button hover effects, and smooth transitions)
- Ensure **clean typography, spacing, and layout balance** for a refined, premium look
- Focus on **delightful details** like hover effects, loading states, and smooth page transitions

<!-- usage-rules-start -->

<!-- phoenix:elixir-start -->

## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you _must_ bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option
- **Always** use Structs instead of plain maps for proper type safety and compile-time guarantees. Structs provide:

  - Compile-time validation of field names (typos in field names will be caught at compile time)
  - Clear documentation of expected fields
  - Pattern matching on struct type
  - Better tooling support and code completion

  **Never do this (maps)**:

      def create_user(name, email) do
        %{name: name, email: email, role: "user"}
      end

  Instead, **always** define and use a struct:

      defmodule User do
        defstruct [:name, :email, role: "user"]
      end

      def create_user(name, email) do
        %User{name: name, email: email}
      end

  **For JSON parsing and external data**, parse to a map then immediately convert to a struct using `Ecto.Changeset` or similar:

      # Parse JSON
      {:ok, json_map} = Jason.decode(json_string)

      # Immediately validate and convert to struct
      changeset = User.changeset(%User{}, json_map)

      case Ecto.Changeset.apply_action(changeset, :insert) do
        {:ok, user_struct} -> # Work with type-safe struct
        {:error, changeset} -> # Handle validation errors
      end

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason
<!-- phoenix:elixir-end -->

<!-- phoenix:phoenix-start -->

## Phoenix guidelines

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it
<!-- phoenix:phoenix-end -->

<!-- phoenix:ecto-start -->

## Ecto Guidelines

### Database

- This project supports **both SQLite and PostgreSQL**. SQLite is the default adapter (development, test, and the typical self-hosted deployment); PostgreSQL is selected via the `DATABASE_TYPE` env var (`postgres`/`postgresql`). See `config/config.exs`.
- **Prefer portable, adapter-agnostic SQL** for everyday queries and migrations so the same code runs on both adapters.
- **Migrations that change column types, nullability, or constraints must handle both adapters.** PostgreSQL supports `ALTER COLUMN` directly; SQLite generally requires a table rebuild (rename → create → copy → drop) or is a no-op when the change is meaningless on SQLite (e.g. `varchar(255)` vs `text`, which SQLite stores identically). Use `Mydia.Repo.Migrations.Helpers` (`postgres?/0`, `sqlite?/0`, `recreate_table/1`, etc.) and branch on the adapter — see `priv/repo/migrations/20260223100000_fix_array_columns_for_postgres.exs` for the Postgres-only / SQLite no-op pattern.
- **Avoid PostgreSQL-only features** (e.g. extensions, advanced types) unless they degrade gracefully or are guarded behind an adapter check, since SQLite remains the default.

### General Guidelines

- **Always** preload Ecto associations in queries when they'll be accessed in templates, ie a message that needs to reference the `message.user.email`
- Remember `import Ecto.Query` and other supporting modules when you write `seeds.exs`
- `Ecto.Schema` fields always use the `:string` type, even for `:text`, columns, ie: `field :name, :string`
- `Ecto.Changeset.validate_number/2` **DOES NOT SUPPORT the `:allow_nil` option**. By default, Ecto validations only run if a change for the given field exists and the change value is not nil, so such as option is never needed
- You **must** use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields
- Fields which are set programatically, such as `user_id`, must not be listed in `cast` calls or similar for security purposes. Instead they must be explicitly set when creating the struct
<!-- phoenix:ecto-end -->

<!-- phoenix:html-start -->

## Phoenix HTML guidelines

- Phoenix templates **always** use `~H` or .html.heex files (known as HEEx), **never** use `~E`
- **Always** use the imported `Phoenix.Component.form/1` and `Phoenix.Component.inputs_for/1` function to build forms. **Never** use `Phoenix.HTML.form_for` or `Phoenix.HTML.inputs_for` as they are outdated
- When building forms **always** use the already imported `Phoenix.Component.to_form/2` (`assign(socket, form: to_form(...))` and `<.form for={@form} id="msg-form">`), then access those forms in the template via `@form[:field]`
- **Always** add unique DOM IDs to key elements (like forms, buttons, etc) when writing templates, these IDs can later be used in tests (`<.form for={@form} id="product-form">`)
- For "app wide" template imports, you can import/alias into the `my_app_web.ex`'s `html_helpers` block, so they will be available to all LiveViews, LiveComponent's, and all modules that do `use MyAppWeb, :html` (replace "my_app" by the actual app name)

- Elixir supports `if/else` but **does NOT support `if/else if` or `if/elsif`. **Never use `else if` or `elseif` in Elixir**, **always\*\* use `cond` or `case` for multiple conditionals.

  **Never do this (invalid)**:

      <%= if condition do %>
        ...
      <% else if other_condition %>
        ...
      <% end %>

  Instead **always** do this:

      <%= cond do %>
        <% condition -> %>
          ...
        <% condition2 -> %>
          ...
        <% true -> %>
          ...
      <% end %>

- HEEx require special tag annotation if you want to insert literal curly's like `{` or `}`. If you want to show a textual code snippet on the page in a `<pre>` or `<code>` block you _must_ annotate the parent tag with `phx-no-curly-interpolation`:

      <code phx-no-curly-interpolation>
        let obj = {key: "val"}
      </code>

  Within `phx-no-curly-interpolation` annotated tags, you can use `{` and `}` without escaping them, and dynamic Elixir expressions can still be used with `<%= ... %>` syntax

- HEEx class attrs support lists, but you must **always** use list `[...]` syntax. You can use the class list syntax to conditionally add classes, **always do this for multiple class values**:

      <a class={[
        "px-2 text-white",
        @some_flag && "py-5",
        if(@other_condition, do: "border-red-500", else: "border-blue-100"),
        ...
      ]}>Text</a>

  and **always** wrap `if`'s inside `{...}` expressions with parens, like done above (`if(@other_condition, do: "...", else: "...")`)

  and **never** do this, since it's invalid (note the missing `[` and `]`):

      <a class={
        "px-2 text-white",
        @some_flag && "py-5"
      }> ...
      => Raises compile syntax error on invalid HEEx attr syntax

- **Never** use `<% Enum.each %>` or non-for comprehensions for generating template content, instead **always** use `<%= for item <- @collection do %>`
- HEEx HTML comments use `<%!-- comment --%>`. **Always** use the HEEx HTML comment syntax for template comments (`<%!-- comment --%>`)
- HEEx allows interpolation via `{...}` and `<%= ... %>`, but the `<%= %>` **only** works within tag bodies. **Always** use the `{...}` syntax for interpolation within tag attributes, and for interpolation of values within tag bodies. **Always** interpolate block constructs (if, cond, case, for) within tag bodies using `<%= ... %>`.

  **Always** do this:

        <div id={@id}>
          {@my_assign}
          <%= if @some_block_condition do %>
            {@another_assign}
          <% end %>
        </div>

  and **Never** do this – the program will terminate with a syntax error:

        <%!-- THIS IS INVALID NEVER EVER DO THIS --%>
        <div id="<%= @invalid_interpolation %>">
          {if @invalid_block_construct do}
          {end}
        </div>

  <!-- phoenix:html-end -->

<!-- phoenix:liveview-start -->

## Phoenix LiveView guidelines

- **Never** use the deprecated `live_redirect` and `live_patch` functions, instead **always** use the `<.link navigate={href}>` and `<.link patch={href}>` in templates, and `push_navigate` and `push_patch` functions LiveViews
- **Avoid LiveComponent's** unless you have a strong, specific need for them
- LiveViews should be named like `AppWeb.WeatherLive`, with a `Live` suffix. When you go to add LiveView routes to the router, the default `:browser` scope is **already aliased** with the `AppWeb` module, so you can just do `live "/weather", WeatherLive`
- Remember anytime you use `phx-hook="MyHook"` and that js hook manages its own DOM, you **must** also set the `phx-update="ignore"` attribute
- **Prefer** file-based hooks in `assets/js/` for hooks longer than a few lines. Colocated JS (`<script :type={ColocatedJS}>`) is available for template-local hooks.

### LiveView 1.2 features

Mydia runs on LiveView 1.2. The following features are available:
- **Colocated CSS** (`<style :type={ColocatedCSS}>`) — template-local CSS extracted at compile time. Not currently in use; Tailwind/DaisyUI via `assets/css/` remains the primary styling path.
- **Colocated JS** (`<script :type={ColocatedJS}>`) — template-local JS extracted at compile time. Available for new hooks; existing hooks remain file-based in `assets/js/`.
- **JS struct auto-encoding** — `Phoenix.LiveView.JS` structs are automatically encoded when passed to `push_event`. No code changes needed.
- **Per-module debug annotations** — `@debug_heex_annotations` can be set per LiveView module to override the global config.
- **Test warning configuration** — individual test warning categories can be raised, warned, or ignored via `config :phoenix_live_view, :test_warnings`.
- **TagFormatter** — a behaviour for formatting `<script>` and `<style>` tags in HEEx at compile time. Not currently in use.

### LiveView streams

- **Always** use LiveView streams for collections for assigning regular lists to avoid memory ballooning and runtime termination with the following operations:

  - basic append of N items - `stream(socket, :messages, [new_msg])`
  - resetting stream with new items - `stream(socket, :messages, [new_msg], reset: true)` (e.g. for filtering items)
  - prepend to stream - `stream(socket, :messages, [new_msg], at: -1)`
  - deleting items - `stream_delete(socket, :messages, msg)`

- When using the `stream/3` interfaces in the LiveView, the LiveView template must 1) always set `phx-update="stream"` on the parent element, with a DOM id on the parent element like `id="messages"` and 2) consume the `@streams.stream_name` collection and use the id as the DOM id for each child. For a call like `stream(socket, :messages, [new_msg])` in the LiveView, the template would be:

      <div id="messages" phx-update="stream">
        <div :for={{id, msg} <- @streams.messages} id={id}>
          {msg.text}
        </div>
      </div>

- LiveView streams are _not_ enumerable, so you cannot use `Enum.filter/2` or `Enum.reject/2` on them. Instead, if you want to filter, prune, or refresh a list of items on the UI, you **must refetch the data and re-stream the entire stream collection, passing reset: true**:

      def handle_event("filter", %{"filter" => filter}, socket) do
        # re-fetch the messages based on the filter
        messages = list_messages(filter)

        {:noreply,
        socket
        |> assign(:messages_empty?, messages == [])
        # reset the stream with the new messages
        |> stream(:messages, messages, reset: true)}
      end

- LiveView streams _do not support counting or empty states_. If you need to display a count, you must track it using a separate assign. For empty states, you can use Tailwind classes:

      <div id="tasks" phx-update="stream">
        <div class="hidden only:block">No tasks yet</div>
        <div :for={{id, task} <- @stream.tasks} id={id}>
          {task.name}
        </div>
      </div>

  The above only works if the empty state is the only HTML block alongside the stream for-comprehension.

- **Never** use the deprecated `phx-update="append"` or `phx-update="prepend"` for collections

### LiveView tests

- `Phoenix.LiveViewTest` module and `LazyHTML` (included) for making your assertions
- Form tests are driven by `Phoenix.LiveViewTest`'s `render_submit/2` and `render_change/2` functions
- Come up with a step-by-step test plan that splits major test cases into small, isolated files. You may start with simpler tests that verify content exists, gradually add interaction tests
- **Always reference the key element IDs you added in the LiveView templates in your tests** for `Phoenix.LiveViewTest` functions like `element/2`, `has_element/2`, selectors, etc
- **Never** tests again raw HTML, **always** use `element/2`, `has_element/2`, and similar: `assert has_element?(view, "#my-form")`
- Instead of relying on testing text content, which can change, favor testing for the presence of key elements
- Focus on testing outcomes rather than implementation details
- Be aware that `Phoenix.Component` functions like `<.form>` might produce different HTML than expected. Test against the output HTML structure, not your mental model of what you expect it to be
- When facing test failures with element selectors, add debug statements to print the actual HTML, but use `LazyHTML` selectors to limit the output, ie:

      html = render(view)
      document = LazyHTML.from_fragment(html)
      matches = LazyHTML.filter(document, "your-complex-selector")
      IO.inspect(matches, label: "Matches")

### Form handling

#### Creating a form from params

If you want to create a form based on `handle_event` params:

    def handle_event("submitted", params, socket) do
      {:noreply, assign(socket, form: to_form(params))}
    end

When you pass a map to `to_form/1`, it assumes said map contains the form params, which are expected to have string keys.

You can also specify a name to nest the params:

    def handle_event("submitted", %{"user" => user_params}, socket) do
      {:noreply, assign(socket, form: to_form(user_params, as: :user))}
    end

#### Creating a form from changesets

When using changesets, the underlying data, form params, and errors are retrieved from it. The `:as` option is automatically computed too. E.g. if you have a user schema:

    defmodule MyApp.Users.User do
      use Ecto.Schema
      ...
    end

And then you create a changeset that you pass to `to_form`:

    %MyApp.Users.User{}
    |> Ecto.Changeset.change()
    |> to_form()

Once the form is submitted, the params will be available under `%{"user" => user_params}`.

In the template, the form form assign can be passed to the `<.form>` function component:

    <.form for={@form} id="todo-form" phx-change="validate" phx-submit="save">
      <.input field={@form[:field]} type="text" />
    </.form>

Always give the form an explicit, unique DOM ID, like `id="todo-form"`.

#### Avoiding form errors

**Always** use a form assigned via `to_form/2` in the LiveView, and the `<.input>` component in the template. In the template **always access forms this**:

    <%!-- ALWAYS do this (valid) --%>
    <.form for={@form} id="my-form">
      <.input field={@form[:field]} type="text" />
    </.form>

And **never** do this:

    <%!-- NEVER do this (invalid) --%>
    <.form for={@changeset} id="my-form">
      <.input field={@changeset[:field]} type="text" />
    </.form>

- You are FORBIDDEN from accessing the changeset in the template as it will cause errors
- **Never** use `<.form let={f} ...>` in the template, instead **always use `<.form for={@form} ...>`**, then drive all form references from the form assign as in `@form[:field]`. The UI should **always** be driven by a `to_form/2` assigned in the LiveView module that is derived from a changeset
<!-- phoenix:liveview-end -->

<!-- usage-rules-end -->
