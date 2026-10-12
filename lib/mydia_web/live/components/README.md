# Reusable LiveView Components

This directory contains reusable LiveView components for metadata search and management workflows.

## Components

### `DisambiguationModalComponent`

A LiveComponent that displays a modal when multiple metadata matches are found from TMDB, allowing users to select the correct match.

**Location:** `lib/mydia_web/live/components/disambiguation_modal_component.ex`

**Usage:**

```heex
<.live_component
  module={MydiaWeb.Live.Components.DisambiguationModalComponent}
  id="disambiguation-modal"
  show={@show_disambiguation_modal}
  matches={@metadata_matches}
  on_select="select_metadata_match"
  on_cancel="close_disambiguation_modal"
/>
```

**Props:**

- `show` (boolean, required) - Controls modal visibility
- `matches` (list, required) - List of TMDB metadata matches to display
- `on_select` (string, required) - Event name to emit when user selects a match (includes `match_id` param)
- `on_cancel` (string, required) - Event name to emit when user cancels

**Features:**

- Responsive grid layout (1 column on mobile, 2 on desktop)
- Displays poster images, titles, years, and overviews
- Handles missing poster images gracefully
- Scrollable results area (max height 60vh)

---

### `ManualSearchModalComponent`

A LiveComponent for manual metadata search when automatic parsing or matching fails. Includes a search input and displays matching results.

**Location:** `lib/mydia_web/live/components/manual_search_modal_component.ex`

**Usage:**

```heex
<.live_component
  module={MydiaWeb.Live.Components.ManualSearchModalComponent}
  id="manual-search-modal"
  show={@show_manual_search_modal}
  failed_title={@failed_release_title}
  search_query={@manual_search_query}
  matches={@metadata_matches}
  on_search="manual_search_submit"
  on_select="select_manual_match"
  on_cancel="close_manual_search_modal"
/>
```

**Props:**

- `show` (boolean, required) - Controls modal visibility
- `failed_title` (string, optional) - The original title that failed to match
- `search_query` (string, required) - Current search query value
- `matches` (list, required) - List of search results to display
- `on_search` (string, required) - Event name to emit when user submits search (includes `search_query` param)
- `on_select` (string, required) - Event name to emit when user selects a result (includes `match_id` and `media_type` params)
- `on_cancel` (string, required) - Event name to emit when user cancels

**Features:**

- Search input with submit button
- Real-time display of search results
- Shows media type badges (TV Show vs Movie)
- Poster images and metadata preview
- Contextual help message showing failed title

---

## Implementation Notes

### Event Handling

All components use standard Phoenix LiveView event handling. Events are sent to the parent LiveView (not the component itself), which maintains all state.

**Example event handlers in parent LiveView:**

```elixir
def handle_event("select_metadata_match", %{"match_id" => match_id}, socket) do
  # Find and process the selected match
  selected_match = Enum.find(socket.assigns.metadata_matches, fn m ->
    to_string(m.provider_id) == match_id
  end)

  {:noreply,
   socket
   |> assign(:show_disambiguation_modal, false)
   |> process_match(selected_match)}
end

def handle_event("close_disambiguation_modal", _params, socket) do
  {:noreply,
   socket
   |> assign(:show_disambiguation_modal, false)
   |> assign(:metadata_matches, [])}
end
```

### Data Format

All components expect metadata matches in the TMDB API format:

```elixir
%{
  provider_id: 12345,              # TMDB ID
  title: "Movie Title",            # For movies
  name: "TV Show Name",            # For TV shows (use title or name)
  poster_path: "/path.jpg",        # Optional
  release_date: "2024-01-15",      # Optional, for movies
  first_air_date: "2024-01-15",    # Optional, for TV shows
  overview: "Plot summary...",     # Optional
  media_type: :movie # or :tv_show # Required for some components
}
```

### Styling

Components use DaisyUI classes and follow the app's design system:

- `modal` and `modal-box` for modals
- `card`, `badge`, `btn` for UI elements
- Responsive grid layouts with Tailwind utilities
- `base-100`, `base-200`, `base-300` for consistent color theming

---

## Migration Guide

### Before (Inline Modal Code)

```heex
<%= if @show_disambiguation_modal do %>
  <div class="modal modal-open">
    <div class="modal-box max-w-4xl">
      <!-- 50+ lines of modal content -->
    </div>
  </div>
<% end %>
```

### After (Using Component)

```heex
<.live_component
  module={MydiaWeb.Live.Components.DisambiguationModalComponent}
  id="disambiguation-modal"
  show={@show_disambiguation_modal}
  matches={@metadata_matches}
  on_select="select_metadata_match"
  on_cancel="close_disambiguation_modal"
/>
```

**Benefits:**

- Reduces template size significantly
- Centralizes modal logic in one place
- Makes testing easier
- Improves maintainability
- Enables consistent UX across the app

---

## Testing

Components can be tested using `Phoenix.LiveViewTest`:

```elixir
test "disambiguation modal displays matches", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/search")

  # Trigger disambiguation
  view
  |> element("button", "Add to Library")
  |> render_click()

  # Verify modal is shown
  assert has_element?(view, "#disambiguation-modal")
  assert has_element?(view, "text", "Multiple Matches Found")

  # Select a match
  view
  |> element("[phx-click='select_metadata_match']")
  |> render_click()

  # Verify modal closes
  refute has_element?(view, "#disambiguation-modal")
end
```

---

## Future Enhancements

Potential improvements for these components:

1. **Keyboard navigation** - Add arrow key support for result selection
2. **Loading states** - Show spinners while search is in progress
3. **Error handling** - Display API errors within components
4. **Caching** - Cache search results to avoid redundant API calls
5. **Thumbnails** - Lazy load poster images for better performance
6. **Accessibility** - Add ARIA attributes for screen readers

---

## Related Files

- `lib/mydia_web/live/search_live/index.ex` - Example usage in SearchLive
- `lib/mydia_web/live/search_live/index.html.heex` - SearchLive template
- `lib/mydia/metadata.ex` - TMDB metadata API client
- `lib/mydia_web.ex` - Component imports in `html_helpers/0`

---

## Questions?

For questions or issues with these components, please refer to:

- Phoenix LiveComponent documentation: https://hexdocs.pm/phoenix_live_view/Phoenix.LiveComponent.html
- Project guidelines in `CLAUDE.md`
- Task tracking in `backlog/tasks/task-172.1`
