# Manual search indexer UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the three manual search dialog defects in #1311: the indexer badge overflowing into the download button, merged trackers whose pages cannot be opened, and filter chips crushing the indexer status card.

**Architecture:** Dedup keeps every tracker's copy as a `SearchResult.Source` (indexer plus info URL) instead of names only. The indexer badge truncates, and for a merged release opens a native popover listing every tracker's page. The `lg` filter chips move under the status card, and the indexer chip caps its label.

**Tech Stack:** Elixir, Phoenix LiveView 1.2, daisyUI 5 / Tailwind v4, ExUnit, Wallaby feature tests, Bypass.

**Spec:** `design/specs/2026-10-31-manual-search-indexer-ui-design.md`

## Global Constraints

- Run every command through `./dev` (`./dev mix test <path>`, `./dev mix precommit`). Feature tests: `./dev feature-test <path> --only feature`, and confirm the output says `Including tags: [:feature]` with a non-zero test count (`test/README.md`).
- Commit with plain `git commit -F <msgfile>` after `git add` of every intended path; check `git show --stat HEAD` after each commit. Never `--no-verify`.
- Fictional media and tracker names only in tests and fixtures, never real titles or real tracker names.
- No em dashes in code comments, docs or commit messages.
- Every info URL that reaches a template goes through `SearchResult.usable_info_url/1`. It is a security boundary (`javascript:` URLs, passkeys, feed paths).
- Menus inside the manual search dialog never use an absolute `dropdown-content` (`no_hover_dropdowns_test.exs`, `lib/mydia_web/components/README.md`): use the native popover pattern.
- User-visible strings go through `gettext`; after adding strings run `./dev mix gettext.extract` (regenerates `priv/gettext/*.pot`). Never edit `.po` files (`lib/mydia_web/gettext/README.md`).

---

### Task 1: Per-tracker sources on `SearchResult` and in dedup

**Files:**
- Create: `lib/mydia/indexers/search_result/source.ex`
- Modify: `lib/mydia/indexers/search_result.ex` (typespec ~line 105, struct field ~line 149, `indexers/1` ~line 194, `info_page_url/1` ~line 313)
- Modify: `lib/mydia/indexers/result_dedup.ex:46-67`
- Test: `test/mydia/indexers/search_result_test.exs`, `test/mydia/indexers/result_dedup_test.exs`
- Fixture updates: `test/mydia_web/live/media_live/show/search_helpers_test.exs:702`, `test/mydia_web/live/media_live/show/modals_test.exs:591`

**Interfaces:**
- Produces:
  - `%Mydia.Indexers.SearchResult.Source{indexer: String.t(), info_url: String.t() | nil}`
  - `SearchResult.sources(SearchResult.t()) :: [Source.t()]`
  - `SearchResult.indexers(SearchResult.t()) :: [String.t()]` (unchanged signature)
  - `SearchResult.usable_info_url(String.t() | nil) :: String.t() | nil`
  - `SearchResult` field `:sources` (default `[]`) replaces `:indexers`.

- [ ] **Step 1: Write the failing `SearchResult` tests**

Append to `test/mydia/indexers/search_result_test.exs` (add `alias Mydia.Indexers.SearchResult.Source` next to the existing aliases):

```elixir
  describe "sources/1 and indexers/1" do
    test "an unmerged result is its own single source" do
      result = search_result(indexer: "Saltmarsh Mirror", info_url: "https://a.example/d/1")

      assert SearchResult.sources(result) == [
               %Source{indexer: "Saltmarsh Mirror", info_url: "https://a.example/d/1"}
             ]

      assert SearchResult.indexers(result) == ["Saltmarsh Mirror"]
    end

    test "a merged result reports every source and its indexer names" do
      sources = [
        %Source{indexer: "Ashvale Commons", info_url: "https://b.example/d/2"},
        %Source{indexer: "Saltmarsh Mirror", info_url: nil}
      ]

      result = search_result(indexer: "Saltmarsh Mirror", sources: sources)

      assert SearchResult.sources(result) == sources
      assert SearchResult.indexers(result) == ["Ashvale Commons", "Saltmarsh Mirror"]
    end
  end

  describe "usable_info_url/1" do
    test "accepts http and https details pages" do
      assert SearchResult.usable_info_url("https://tracker.example/details/42") ==
               "https://tracker.example/details/42"

      assert SearchResult.usable_info_url(" http://tracker.example/details/42 ") ==
               "http://tracker.example/details/42"
    end

    test "rejects scripts, hostless, credential and feed URLs, blanks and nil" do
      for url <- [
            "javascript:alert(1)",
            "https://",
            "https://tracker.example/details/42?passkey=0123456789abcdef0123456789abcdef",
            "https://tracker.example/rss/abc",
            "",
            nil
          ] do
        assert SearchResult.usable_info_url(url) == nil, "expected #{inspect(url)} to be refused"
      end
    end
  end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `./dev mix test test/mydia/indexers/search_result_test.exs`
Expected: compile error, `Mydia.Indexers.SearchResult.Source.__struct__/1 is undefined`.

- [ ] **Step 3: Create the `Source` struct**

`lib/mydia/indexers/search_result/source.ex`:

```elixir
defmodule Mydia.Indexers.SearchResult.Source do
  @moduledoc """
  One tracker's copy of a release: the indexer that returned it and that
  indexer's details-page URL as reported. The URL is unchecked; render it only
  through `Mydia.Indexers.SearchResult.usable_info_url/1`.
  """

  @enforce_keys [:indexer]
  defstruct [:indexer, :info_url]

  @type t :: %__MODULE__{indexer: String.t(), info_url: String.t() | nil}
end
```

- [ ] **Step 4: Replace `indexers` with `sources` in `SearchResult`**

In `lib/mydia/indexers/search_result.ex`:

1. Add `alias Mydia.Indexers.SearchResult.Source` beside the existing `alias Mydia.Indexers.Structs.TrackerTerms`.
2. Typespec: replace `indexers: [String.t()],` with `sources: [Source.t()],`.
3. Struct: replace the `indexers: [],` field and its comment with:

```elixir
    # Every tracker's copy of this release, filled in by ResultDedup when it
    # merges copies from several trackers. Empty until then; read it through
    # sources/1, which falls back to this result's own indexer and info_url.
    sources: [],
```

4. Replace the `indexers/1` doc and both clauses with:

```elixir
  @doc """
  Every tracker's copy of this release.

  Dedup merges copies of one release from several trackers into the best one
  and records each copy's indexer and info URL in `:sources`. A result that was
  never merged reports just itself.
  """
  @spec sources(t()) :: [Source.t()]
  def sources(%__MODULE__{sources: [_ | _] = sources}), do: sources

  def sources(%__MODULE__{indexer: indexer, info_url: info_url}),
    do: [%Source{indexer: indexer, info_url: info_url}]

  @doc "Every tracker that returned this release, by name."
  @spec indexers(t()) :: [String.t()]
  def indexers(%__MODULE__{} = result), do: result |> sources() |> Enum.map(& &1.indexer)
```

5. Split `info_page_url/1`: keep its existing `@doc` (examples unchanged) and `@spec`, and replace its two clauses with a delegate plus the extracted check:

```elixir
  def info_page_url(%__MODULE__{info_url: info_url}), do: usable_info_url(info_url)

  @doc """
  The URL check behind `info_page_url/1`, for a bare URL such as a merged
  copy's `Source.info_url`. Same rules: absolute `http`/`https` with a host,
  no credentials, no feed or download path; otherwise `nil`.
  """
  @spec usable_info_url(String.t() | nil) :: String.t() | nil
  def usable_info_url(info_url) when is_binary(info_url) do
    trimmed = String.trim(info_url)

    cond do
      trimmed == "" -> nil
      not linkable_scheme?(trimmed) -> nil
      # A redacted link would be dead, and the raw one would put the key in
      # the page, so a link carrying credentials is not offered at all.
      Mydia.Downloads.Client.Helpers.redact_url(trimmed) != trimmed -> nil
      # Feed and download paths carry the account key even when it is too
      # short to look like one (UNIT3D /rss/<key>, /torrent/download/<id>.<key>).
      credential_path?(trimmed) -> nil
      true -> trimmed
    end
  end

  def usable_info_url(_info_url), do: nil
```

The comments are moved verbatim from the old clause.

- [ ] **Step 5: Run the `SearchResult` tests**

Run: `./dev mix test test/mydia/indexers/search_result_test.exs`
Expected: all pass, including the existing `info_page_url/1` describes (doctests too if the file runs them).

- [ ] **Step 6: Rewrite the dedup tests for sources**

Replace `test/mydia/indexers/result_dedup_test.exs` with:

```elixir
defmodule Mydia.Indexers.ResultDedupTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.{ResultDedup, SearchResult}
  alias Mydia.Indexers.SearchResult.Source

  @title "Glass.Harbor.2019.1080p.WEB-DL.x264-GRP"

  defp result(indexer, seeders, title \\ @title, info_url \\ nil) do
    %SearchResult{
      title: title,
      size: 1_000,
      seeders: seeders,
      leechers: 0,
      download_url: "https://#{indexer}.test/#{seeders}.torrent",
      info_url: info_url,
      indexer: indexer
    }
  end

  test "a merged release records every tracker that returned it" do
    [merged] =
      ResultDedup.deduplicate([result("Nyaa", 5), result("TorrentDay", 40), result("EZTV", 12)])

    assert SearchResult.indexers(merged) == ["EZTV", "Nyaa", "TorrentDay"]
  end

  test "a merged release keeps each tracker's own info URL" do
    [merged] =
      ResultDedup.deduplicate([
        result("Nyaa", 5, @title, "https://nyaa.example/details/1"),
        result("TorrentDay", 40, @title, "https://td.example/details/2")
      ])

    assert merged.sources == [
             %Source{indexer: "Nyaa", info_url: "https://nyaa.example/details/1"},
             %Source{indexer: "TorrentDay", info_url: "https://td.example/details/2"}
           ]
  end

  test "two copies from one tracker collapse to one source, preferring a usable URL" do
    [merged] =
      ResultDedup.deduplicate([
        result("Nyaa", 5, @title, "javascript:alert(1)"),
        result("Nyaa", 7, @title, "https://nyaa.example/details/1"),
        result("TorrentDay", 40)
      ])

    assert merged.sources == [
             %Source{indexer: "Nyaa", info_url: "https://nyaa.example/details/1"},
             %Source{indexer: "TorrentDay", info_url: nil}
           ]
  end

  test "the copy with the most seeders still wins the merge" do
    [merged] = ResultDedup.deduplicate([result("Nyaa", 5), result("TorrentDay", 40)])

    assert merged.indexer == "TorrentDay"
    assert merged.seeders == 40
    assert merged.download_url == "https://TorrentDay.test/40.torrent"
  end

  test "merging an already merged release keeps every source" do
    first = %{
      result("Nyaa", 5)
      | sources: [
          %Source{indexer: "EZTV", info_url: "https://eztv.example/details/3"},
          %Source{indexer: "Nyaa", info_url: nil}
        ]
    }

    [merged] = ResultDedup.deduplicate([first, result("TorrentDay", 40)])

    assert merged.sources == [
             %Source{indexer: "EZTV", info_url: "https://eztv.example/details/3"},
             %Source{indexer: "Nyaa", info_url: nil},
             %Source{indexer: "TorrentDay", info_url: nil}
           ]
  end

  test "different releases are not merged" do
    results =
      ResultDedup.deduplicate([
        result("Nyaa", 5),
        result("TorrentDay", 40, "Glass.Harbor.2019.2160p.WEB-DL.x265-GRP")
      ])

    assert length(results) == 2
    assert Enum.all?(results, &(&1.sources == []))
  end
end
```

- [ ] **Step 7: Run them to verify the new ones fail**

Run: `./dev mix test test/mydia/indexers/result_dedup_test.exs`
Expected: the three `sources` tests fail (`merged.sources` is `[]`, dedup still writes `:indexers`, which is now a KeyError).

- [ ] **Step 8: Build sources in dedup**

In `lib/mydia/indexers/result_dedup.ex`, replace the `indexers = ...` block and the return of `merge_duplicates/1` with:

```elixir
    # The manual search indexer filter matches any tracker that returned the
    # release, and the indexer badge links each tracker's own page, so every
    # copy's indexer and info URL is kept, one per tracker.
    sources =
      duplicates
      |> Enum.flat_map(&SearchResult.sources/1)
      |> Enum.group_by(& &1.indexer)
      |> Enum.map(fn {_indexer, [first | _] = copies} ->
        Enum.find(copies, first, &SearchResult.usable_info_url(&1.info_url))
      end)
      |> Enum.sort_by(& &1.indexer)

    %{best | sources: sources}
```

- [ ] **Step 9: Move the remaining `indexers:` fixtures to `sources:`**

`test/mydia_web/live/media_live/show/search_helpers_test.exs:702`: replace `| indexers: ["Nyaa", "TorrentDay"]` with

```elixir
        | sources: [
            %Mydia.Indexers.SearchResult.Source{indexer: "Nyaa"},
            %Mydia.Indexers.SearchResult.Source{indexer: "TorrentDay"}
          ]
```

`test/mydia_web/live/media_live/show/modals_test.exs:591`: replace the `modal_html` call with

```elixir
      html =
        modal_html(%{
          indexer: "TorrentDay",
          sources:
            for(name <- ["EZTV", "Nyaa", "TorrentDay"],
              do: %Mydia.Indexers.SearchResult.Source{indexer: name}
            )
        })
```

Then confirm nothing else writes the old field: `grep -rn "indexers: \[" lib test | grep -v "filter_options\|indexers: \[{" ` should show no `SearchResult` construction (the hits in `indexers_test.exs` and `search_helpers_test.exs:642,657` are unrelated config and filter-option lists).

- [ ] **Step 10: Run the affected suites**

Run: `./dev mix test test/mydia/indexers/ test/mydia_web/live/media_live/show/search_helpers_test.exs test/mydia_web/live/media_live/show/modals_test.exs test/mydia_web/live/media_live/show/manual_search_info_link_test.exs test/mydia_web/live/media_live/manual_search_streaming_test.exs`
Expected: all pass.

- [ ] **Step 11: Commit**

```bash
git add lib/mydia/indexers/search_result/source.ex lib/mydia/indexers/search_result.ex lib/mydia/indexers/result_dedup.ex test/mydia/indexers/search_result_test.exs test/mydia/indexers/result_dedup_test.exs test/mydia_web/live/media_live/show/search_helpers_test.exs test/mydia_web/live/media_live/show/modals_test.exs
printf 'fix(search): keep every merged tracker'"'"'s info URL (#1311)\n\nDedup recorded only the other trackers'"'"' names, so a merged release could\nonly link the winning copy'"'"'s page. Each copy is now a SearchResult.Source\nwith its indexer and info URL, and the URL check is usable_info_url/1.\n' > /tmp/msg-1311-task1.txt
git commit -F /tmp/msg-1311-task1.txt
git show --stat HEAD
```

---

### Task 2: Indexer badge truncates and lists every tracker

**Files:**
- Modify: `lib/mydia_web/live/media_live/show/manual_search_components.ex` (`indexer_badge/1` ~line 396-436, its two call sites ~line 218 and ~line 325)
- Test: `test/mydia_web/live/media_live/show/modals_test.exs` (the `manual_search_modal/1` describe that holds `modal_html/2`)

**Interfaces:**
- Consumes: `SearchResult.sources/1`, `SearchResult.usable_info_url/1`, `SearchResult.info_page_url/1`, `%Source{}` (Task 1).
- Produces: per row, the column badge has DOM id `"#{row_id}-indexer-badge"` and the inline (below `lg`) badge `"#{row_id}-indexer-badge-inline"`. For a merged release the badge is a `<button popovertarget=...>` and the menu is `<ul id="#{badge_id}-menu" popover>`. Task 4 selects on these ids.

- [ ] **Step 1: Write the failing component tests**

Add inside the describe block of `modals_test.exs` that defines `modal_html/2`, after the "several trackers" test (alias `Mydia.Indexers.SearchResult.Source` at the top of the module if not already):

```elixir
    test "a merged release lists each tracker's page in a popover menu" do
      html =
        modal_html(%{
          indexer: "Saltmarsh Mirror",
          sources: [
            %Source{indexer: "Ashvale Commons", info_url: "https://a.example/details/1"},
            %Source{indexer: "Brinewater Exchange", info_url: "javascript:alert(1)"},
            %Source{indexer: "Saltmarsh Mirror", info_url: "https://s.example/details/2"}
          ]
        })

      doc = LazyHTML.from_fragment(html)
      badge = LazyHTML.query(doc, "#search-result-00000-1-indexer-badge")

      assert LazyHTML.attribute(badge, "popovertarget") ==
               ["search-result-00000-1-indexer-badge-menu"]

      menu = LazyHTML.query(doc, "#search-result-00000-1-indexer-badge-menu[popover]")

      assert menu |> LazyHTML.query("a[href]") |> LazyHTML.attribute("href") ==
               ["https://a.example/details/1", "https://s.example/details/2"]

      # The tracker with an unusable URL is named but not linked.
      assert LazyHTML.text(menu) =~ "Brinewater Exchange"
      refute html =~ "javascript:alert"
    end

    test "a single-tracker release stays a direct link with a truncating label" do
      html = modal_html(%{indexer: "Saltmarsh Mirror", info_url: "https://s.example/details/2"})
      doc = LazyHTML.from_fragment(html)

      link = LazyHTML.query(doc, "a#search-result-00000-1-indexer-badge")
      assert LazyHTML.attribute(link, "href") == ["https://s.example/details/2"]
      assert link |> LazyHTML.query("span.truncate") |> LazyHTML.text() == "Saltmarsh Mirror"
      assert doc |> LazyHTML.query("[popover]") |> Enum.count() == 0
    end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `./dev mix test test/mydia_web/live/media_live/show/modals_test.exs`
Expected: both new tests fail (no element with id `search-result-00000-1-indexer-badge`).

- [ ] **Step 3: Rewrite `indexer_badge/1`**

Replace the comment, attrs and body of `indexer_badge/1` with:

```elixir
  # Indexer badge. One tracker: a direct link to the release's page when
  # usable, else a plain badge. Several (a dedup merge): a button opening a
  # menu of every tracker's page. The label truncates so a long tracker name
  # never runs into the download column; the title lists every tracker.
  #
  # The menu is a native popover with CSS anchor positioning (the
  # #downloads-more pattern), not an absolute dropdown-content: the results
  # list scrolls inside the dialog and would clip it. flip-block opens it
  # upward near the bottom edge.
  attr :id, :string, required: true
  attr :result, SearchResult, required: true

  defp indexer_badge(assigns) do
    sources = SearchResult.sources(assigns.result)
    names = Enum.map(sources, & &1.indexer)

    assigns =
      assign(assigns,
        info_page_url: SearchResult.info_page_url(assigns.result),
        links: Enum.map(sources, &{&1.indexer, SearchResult.usable_info_url(&1.info_url)}),
        merged?: length(sources) > 1,
        all_indexers: Enum.join(names, ", ")
      )

    ~H"""
    <%= cond do %>
      <% @merged? -> %>
        <button
          id={@id}
          type="button"
          class="badge badge-outline badge-sm max-w-full min-w-0 cursor-pointer gap-1 hover:border-primary hover:text-primary transition-colors"
          popovertarget={"#{@id}-menu"}
          style={"anchor-name:--#{@id}"}
          title={@all_indexers}
          aria-label={gettext("Trackers for this release: %{indexers}", indexers: @all_indexers)}
        >
          <span class="truncate">{indexer_label(@result)}</span>
          <.icon name="hero-chevron-down" class="w-3 h-3 shrink-0" />
        </button>
        <ul
          id={"#{@id}-menu"}
          popover
          class="dropdown dropdown-end menu bg-base-100 rounded-box w-64 p-2 shadow-lg border border-base-300 ms-0 whitespace-normal before:hidden"
          style={"position-anchor:--#{@id};position-try-fallbacks:flip-block"}
        >
          <li :for={{indexer, url} <- @links} class={[!url && "menu-disabled"]}>
            <a :if={url} href={url} target="_blank" rel="noopener noreferrer" class="gap-2">
              <span class="min-w-0 break-words">{indexer}</span>
              <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3 shrink-0" />
            </a>
            <span :if={!url} class="break-words">{indexer}</span>
          </li>
        </ul>
      <% @info_page_url -> %>
        <a
          id={@id}
          href={@info_page_url}
          target="_blank"
          rel="noopener noreferrer"
          class="badge badge-outline badge-sm max-w-full min-w-0 gap-1 hover:border-primary hover:text-primary transition-colors"
          title={gettext("View this release on %{indexer}", indexer: @result.indexer)}
        >
          <span class="truncate">{indexer_label(@result)}</span>
          <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3 shrink-0" />
        </a>
      <% true -> %>
        <%!-- No usable URL: a plain badge. It used to hide on xs screens, since a
             non-actionable badge earned no room in a dense mobile row; it now
             always shows because it is the only place a row names its trackers. --%>
        <span
          id={@id}
          class="badge badge-outline badge-sm max-w-full min-w-0"
          title={@all_indexers}
        >
          <span class="truncate">{indexer_label(@result)}</span>
        </span>
    <% end %>
    """
  end
```

Note the single-source link loses the old `if(@single?, ...)` title branch: a merged result never reaches that branch now, so its title is always the "View this release on" text.

- [ ] **Step 4: Pass ids at both call sites**

At the inline call (~line 218, inside `<span class="lg:hidden">`):

```elixir
          <.indexer_badge id={"#{@id}-indexer-badge-inline"} result={@result} />
```

At the column call (~line 325, inside `<div id={"#{@id}-indexer"} ...>`):

```elixir
      <.indexer_badge id={"#{@id}-indexer-badge"} result={@result} />
```

- [ ] **Step 5: Regenerate the gettext template**

Run: `./dev mix gettext.extract`
Expected: `priv/gettext/default.pot` (or the domain's `.pot`) gains `"Trackers for this release: %{indexers}"`.

- [ ] **Step 6: Run the tests**

Run: `./dev mix test test/mydia_web/live/media_live/show/modals_test.exs test/mydia_web/live/media_live/show/manual_search_info_link_test.exs test/mydia_web/live/media_live/show/no_hover_dropdowns_test.exs test/mydia_web/live/media_live/manual_search_streaming_test.exs`
Expected: all pass. If `manual_search_info_link_test.exs` line ~83 (`span.badge.badge-outline[title]`) fails, the plain-badge branch lost its `title`; it must keep `title={@all_indexers}`.

- [ ] **Step 7: Commit**

```bash
git add lib/mydia_web/live/media_live/show/manual_search_components.ex test/mydia_web/live/media_live/show/modals_test.exs priv/gettext
printf 'fix(search): truncate the indexer badge and list every merged tracker (#1311)\n\nA long tracker name ran into the download button, and a merged release only\nopened the winning copy'"'"'s page. The label now truncates, and a merged\nrelease opens a popover menu linking each tracker'"'"'s page.\n' > /tmp/msg-1311-task2.txt
git commit -F /tmp/msg-1311-task2.txt
git show --stat HEAD
```

---

### Task 3: Filter chips under the status card, indexer chip capped

**Files:**
- Modify: `lib/mydia_web/live/media_live/show/manual_search_filters.ex` (`active_chips/1` ~line 93-116, `chips/1` ~line 321-344)
- Modify: `lib/mydia_web/live/media_live/show/modals.ex:997-1017`
- Test: `test/mydia_web/live/media_live/show/manual_search_filters_test.exs` (create)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: chip DOM ids unchanged (`manual-search-chip-<dimension>`, `manual-search-lg-chip-<dimension>`). The `lg` chip row renders after `#indexer-search-status`, not beside it. Task 4 selects `#manual-search-lg-chip-indexer`.

- [ ] **Step 1: Write the failing chip tests**

Create `test/mydia_web/live/media_live/show/manual_search_filters_test.exs`:

```elixir
defmodule MydiaWeb.MediaLive.Show.ManualSearchFiltersTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias MydiaWeb.MediaLive.Show.ManualSearchFilters

  defp indexer_chip(indexers) do
    render_component(&ManualSearchFilters.active_chips/1, indexer_filters: indexers)
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#manual-search-chip-indexer")
  end

  test "up to two indexers are named in full" do
    chip = indexer_chip(["Ashvale Commons", "Saltmarsh Mirror"])

    assert LazyHTML.text(chip) =~ "Ashvale Commons, Saltmarsh Mirror"
  end

  test "three or more indexers name two and count the rest, listing all in the title" do
    names = ["Ashvale Commons", "Brinewater Exchange", "Saltmarsh Mirror", "Westmarch Lantern"]
    chip = indexer_chip(names)

    assert LazyHTML.text(chip) =~ "Ashvale Commons, Brinewater Exchange +2 more"
    refute LazyHTML.text(chip) =~ "Westmarch Lantern"
    assert LazyHTML.attribute(chip, "title") == [Enum.join(names, ", ")]
  end

  test "other dimensions keep joining every value" do
    html = render_component(&ManualSearchFilters.active_chips/1, source_filters: ["REMUX", "BluRay"])

    assert html =~ "REMUX, BluRay"
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `./dev mix test test/mydia_web/live/media_live/show/manual_search_filters_test.exs`
Expected: the "+2 more" test fails (the chip shows all four names, no `title`).

- [ ] **Step 3: Cap the indexer chip label**

In `manual_search_filters.ex`, make `chips/1` return `{dimension, label, title}` triples. Replace its body with:

```elixir
  defp chips(assigns) do
    [
      {"quality", Enum.map(assigns.quality_filters, &quality_label/1)},
      {"indexer", assigns.indexer_filters},
      {"source", assigns.source_filters},
      {"codec", assigns.codec_filters}
    ]
    |> Enum.reject(fn {_dimension, values} -> values == [] end)
    |> Enum.map(fn
      # Indexer names are long and a user may tick many, so the chip names two
      # and counts the rest; the title lists them all.
      {"indexer", names} -> {"indexer", indexer_chip_label(names), Enum.join(names, ", ")}
      {dimension, values} -> {dimension, Enum.join(values, ", "), nil}
    end)
    |> then(fn chips ->
      if assigns.min_seeders > 0,
        do:
          chips ++
            [
              {"min_seeders",
               ngettext("≥ %{count} seed", "≥ %{count} seeds", assigns.min_seeders,
                 count: assigns.min_seeders
               ), nil}
            ],
        else: chips
    end)
  end

  defp indexer_chip_label([_, _, _ | _] = names) do
    {shown, rest} = Enum.split(names, 2)

    gettext("%{indexers} +%{count} more",
      indexers: Enum.join(shown, ", "),
      count: length(rest)
    )
  end

  defp indexer_chip_label(names), do: Enum.join(names, ", ")
```

In `active_chips/1`, change the comprehension and the chip's attributes:

```heex
      <span
        :for={{dimension, label, title} <- @chips}
        id={"#{@id_prefix}-#{dimension}"}
        class="badge badge-soft badge-primary shrink-0 gap-1 whitespace-nowrap"
        title={title}
      >
        {label}
        <button
          type="button"
          class="cursor-pointer opacity-70 hover:opacity-100"
          phx-click="remove_search_filter"
          phx-value-dimension={dimension}
          aria-label={gettext("Remove filter: %{filter}", filter: title || label)}
        >
          <.icon name="hero-x-mark" class="w-3 h-3" />
        </button>
      </span>
```

`active_count/1` uses `length/1` and needs no change.

- [ ] **Step 4: Move the `lg` chips under the status card**

In `modals.ex`, replace the block from `<%!-- Per-indexer search progress, and the active filters from lg --%>` through its closing `</div>` (lines ~997-1017) with:

```heex
            <%!-- Per-indexer search progress, then the active filters from lg.
                 Stacked, not side by side: beside the status card the chips
                 claimed their full width first and crushed the card to a
                 sliver once several filters were active (#1311). --%>
            <div class="px-4 pt-3">
              <.indexer_search_status
                progress={@indexer_progress}
                cardigann={@cardigann_summary}
                retry_event="retry_indexer"
                retest_paused_event="retest_paused"
              />
              <ManualSearchFilters.active_chips
                :if={@filters_visible?}
                id_prefix="manual-search-lg-chip"
                class="hidden flex-wrap pb-3 lg:flex"
                quality_filters={@quality_filters}
                source_filters={@source_filters}
                codec_filters={@codec_filters}
                indexer_filters={@indexer_filters}
                min_seeders={@min_seeders}
              />
            </div>
```

- [ ] **Step 5: Regenerate the gettext template**

Run: `./dev mix gettext.extract`
Expected: the `.pot` gains `"%{indexers} +%{count} more"`.

- [ ] **Step 6: Run the tests**

Run: `./dev mix test test/mydia_web/live/media_live/show/manual_search_filters_test.exs test/mydia_web/live/media_live/manual_search_streaming_test.exs test/mydia_web/live/media_live/show/modals_test.exs`
Expected: all pass, including the existing `#manual-search-chip-indexer` remove-chip test in the streaming suite.

- [ ] **Step 7: Commit**

```bash
git add lib/mydia_web/live/media_live/show/manual_search_filters.ex lib/mydia_web/live/media_live/show/modals.ex test/mydia_web/live/media_live/show/manual_search_filters_test.exs priv/gettext
printf 'fix(search): stack filter chips under the indexer status card (#1311)\n\nFrom lg the chips sat beside the status card and took their full width\nfirst, crushing the card. They now wrap in their own row beneath it, and\nthe indexer chip names two indexers and counts the rest.\n' > /tmp/msg-1311-task3.txt
git commit -F /tmp/msg-1311-task3.txt
git show --stat HEAD
```

---

### Task 4: Browser test for the dialog's geometry

**Files:**
- Create: `test/mydia_web/features/manual_search_layout_test.exs`

**Interfaces:**
- Consumes: `#indexer-search-status`, `#manual-search-lg-chip-indexer` (Task 3), `[id$='-indexer-badge']` and `[id$='-indexer-badge-menu']` (Task 2); `MydiaWeb.FeatureCase` helpers `login_as_admin/1`, `resize_window/3`, `visit_liveview/2`, `js_click/2`, `eval_js/2,3`; `Mydia.IndexerMock.mock_prowlarr_all/2`.

- [ ] **Step 1: Confirm feature tests run in this worktree**

Run: `./dev feature-test test/mydia_web/features/smoke_test.exs --only feature`
Expected: `Including tags: [:feature]` and a non-zero passing count. If the LiveView socket never connects, follow `test/README.md` before continuing.

- [ ] **Step 2: Write the test**

`test/mydia_web/features/manual_search_layout_test.exs`:

```elixir
defmodule MydiaWeb.Features.ManualSearchLayoutTest do
  @moduledoc """
  The manual search dialog keeps its indexer status, filter chips and indexer
  badge legible from `lg` with every filter dimension active (#1311).

  Before the fix, at 1143px with four indexers ticked: the status summary
  beside the chips was about 80px wide, the indexer column's badge ran past
  its 9rem cell into the download button, and a merged release offered no
  way to open any tracker's page but the winner's.
  """
  use MydiaWeb.FeatureCase, async: false

  import Mydia.MediaFixtures, only: [media_item_fixture: 1]

  alias Mydia.IndexerMock
  alias Mydia.Settings

  @moduletag :feature

  @title "Glass.Harbor.2019.1080p.BluRay.x264-GROUP"
  @magnet "magnet:?xt=urn:btih:" <> String.duplicate("ab", 20)

  # Fictional trackers; the winner (most seeders) has the long name.
  @trackers [
    "The Westmarch Lantern Archive Network",
    "Saltmarsh Mirror",
    "Brinewater Exchange",
    "Ashvale Commons"
  ]

  # Below this the summary's "N results · done/total indexers" line wraps
  # word by word, which is what the report showed.
  @readable_px 300

  defp results do
    merged =
      for {tracker, i} <- Enum.with_index(@trackers) do
        %{
          title: @title,
          seeders: 50 - i,
          magnet_url: @magnet,
          indexer: tracker,
          info_url: "https://tracker#{i}.example/details/#{i}"
        }
      end

    merged ++
      [
        %{
          title: "Glass.Harbor.2019.2160p.WEB-DL.x265-GROUP",
          seeders: 20,
          indexer: "Saltmarsh Mirror",
          info_url: "https://tracker1.example/details/99"
        }
      ]
  end

  setup do
    Settings.list_indexer_configs()
    |> Enum.reject(&Settings.runtime_config?/1)
    |> Enum.each(&Settings.update_indexer_config(&1, %{enabled: false}))

    bypass = Bypass.open()
    IndexerMock.mock_prowlarr_all(bypass, results: results())

    {:ok, _indexer} =
      Settings.create_indexer_config(%{
        name: "Fictional Prowlarr",
        type: :prowlarr,
        base_url: "http://localhost:#{bypass.port}",
        api_key: "test-key",
        enabled: true
      })

    %{movie: media_item_fixture(%{type: "movie", title: "Glass Harbor", year: 2019})}
  end

  defp width_of(session, selector) do
    eval_js(
      session,
      """
      var el = document.querySelector(arguments[0]);
      return el ? Math.round(el.getBoundingClientRect().width) : -1;
      """,
      [selector]
    )
  end

  # How far the lg column's indexer badge runs past the right edge of its
  # grid cell; positive is overflow into the download button.
  defp badge_overflow_px(session) do
    eval_js(session, """
    var badge = document.querySelector("[id$='-indexer-badge']");
    if (!badge) return null;
    var cell = badge.parentElement.getBoundingClientRect();
    return Math.round(badge.getBoundingClientRect().right - cell.right);
    """)
  end

  defp open_menu(session) do
    eval_js(session, """
    var menu = document.querySelector("[id$='-indexer-badge-menu']:popover-open");
    if (!menu) return null;
    var r = menu.getBoundingClientRect();
    return {
      links: menu.querySelectorAll("a[href]").length,
      inside: r.left >= 0 && r.top >= 0 &&
              r.right <= window.innerWidth && r.bottom <= window.innerHeight
    };
    """)
  end

  defp tick(session, selector, chip) do
    js_click(session, selector)
    assert Wallaby.Browser.has_css?(session, chip)
  end

  for {w, h} <- [{1024, 768}, {1440, 900}] do
    @tag :feature
    test "status, chips and indexer badge stay legible at #{w}px", %{session: session, movie: movie} do
      login_as_admin(session)

      session
      |> resize_window(unquote(w), unquote(h))
      |> visit_liveview("/media/#{movie.id}")

      js_click(session, "#manual-search-button")
      assert Wallaby.Browser.has_css?(session, "#indexer-search-status[aria-busy='false']")

      for tracker <- @trackers do
        tick(
          session,
          ~s(#manual-search-filter-form input[name="indexer[]"][value="#{tracker}"]),
          "#manual-search-lg-chip-indexer"
        )
      end

      tick(
        session,
        ~s(#manual-search-filter-form input[name="quality[]"][value="1080p"]),
        "#manual-search-lg-chip-quality"
      )

      tick(session, ~s(#manual-search-filter-form input[name="source[]"]), "#manual-search-lg-chip-source")
      tick(session, ~s(#manual-search-filter-form input[name="codec[]"]), "#manual-search-lg-chip-codec")

      summary = width_of(session, "#indexer-search-status summary")

      assert summary >= @readable_px,
             "at #{unquote(w)}px the indexer status summary was #{summary}px wide"

      overflow = badge_overflow_px(session)

      assert is_integer(overflow) and overflow <= 0,
             "at #{unquote(w)}px the indexer badge ran #{inspect(overflow)}px past its column"

      js_click(session, "[id$='-indexer-badge']")

      assert %{"links" => 4, "inside" => true} = open_menu(session),
             "at #{unquote(w)}px the merged badge's menu did not open fully on screen " <>
               "with a link per tracker"
    end
  end
end
```

If `quality[]` uses a different value than `"1080p"` for this release (check the rendered sidebar with a `LazyHTML` dump), use that value; the point is to keep the merged 1080p release in the list.

- [ ] **Step 3: Run it**

Run: `./dev feature-test test/mydia_web/features/manual_search_layout_test.exs --only feature`
Expected: `Including tags: [:feature]`, 2 tests, 0 failures.

- [ ] **Step 4: Prove it catches the bug**

Temporarily put `modals.ex` back to `origin/master` from a scratch copy (never `git stash`: the stack is shared across worktrees), run the test, and restore:

```bash
cp lib/mydia_web/live/media_live/show/modals.ex /tmp/issue1311-modals.ex
git show origin/master:lib/mydia_web/live/media_live/show/modals.ex > lib/mydia_web/live/media_live/show/modals.ex
./dev feature-test test/mydia_web/features/manual_search_layout_test.exs --only feature
cp /tmp/issue1311-modals.ex lib/mydia_web/live/media_live/show/modals.ex
git diff --stat
```

Expected: the reverted run fails the summary-width assertion; `git diff --stat` afterwards is empty. (Reverting `manual_search_components.ex` alone would not compile against Task 1's struct, so the badge assertions are covered by Task 2's component tests and by reading this test's failure messages, not by a revert.)

- [ ] **Step 5: Commit**

```bash
git add test/mydia_web/features/manual_search_layout_test.exs
printf 'test(search): guard the manual search dialog geometry from lg (#1311)\n' > /tmp/msg-1311-task4.txt
git commit -F /tmp/msg-1311-task4.txt
git show --stat HEAD
```

---

### Task 5: Precommit and push

- [ ] **Step 1: Run precommit**

Run: `./dev mix precommit`
If it exceeds the Bash timeout, run its steps separately (format, compile with warnings as errors, credo, the test suite in chunks), as `test/README.md` describes.
Expected: clean. Fix anything in files this plan touched.

- [ ] **Step 2: Check co-changes and the diff against master**

```bash
git fetch origin master
git diff --stat origin/master...HEAD
```

Expected files: the spec, this plan, `source.ex`, `search_result.ex`, `result_dedup.ex`, `manual_search_components.ex`, `manual_search_filters.ex`, `modals.ex`, `priv/gettext/*.pot`, and the test files above. Any other file is a stale-read signal: investigate before pushing.

- [ ] **Step 3: Push**

```bash
git push -u origin HEAD:fix/manual-search-indexer-ui-1311
```

Open the PR only when the user asks for one.
