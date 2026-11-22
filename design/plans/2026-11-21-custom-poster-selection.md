# Custom Poster Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an admin replace a media item's poster with a TMDB/TVDB alternative, an upload, or an image already in the item's folder, keeping that choice across metadata refreshes until it is reset.

**Architecture:** A nullable `media_items.poster_override` column wins over `metadata.poster_path` through one resolver, `Mydia.Media.Posters.effective_path/1`. Uploads and folder copies are written to `<generated_media_path>/posters/` and served from `/generated/posters/`. The player reaches those files over HTTP via `serverUrl`, and over p2p via a new `/artwork/<file>` proxy route that the server answers from an `artwork:` session.

**Tech Stack:** Elixir/Phoenix LiveView, Ecto (SQLite + PostgreSQL), daisyUI, Flutter/Dart (Riverpod), the iroh p2p NIF.

**Spec:** `design/specs/2026-11-21-custom-poster-selection-design.md`

## Global Constraints

- The migration column is `:text`, never `:string` (`test/mydia/repo/migrations/no_varchar_columns_test.exs`).
- The migration timestamp is a real one, checked for duplicates across every remote branch (AGENTS.md, "Migration filenames").
- Accepted formats: JPEG, PNG and WebP, detected by magic bytes. The stored extension is `jpg`, `png` or `webp`.
- Size cap: 10 MB (`10_000_000` bytes), both in `allow_upload` and in `Posters`.
- Hosted path shape: `/generated/posters/<media_item_id>-<sha8>.<ext>`, where `sha8` is the first 8 lowercase hex characters of the image's SHA-256.
- The p2p filename regex is exactly `^[0-9a-f-]+-[0-9a-f]{8}\.(jpg|png|webp)$`.
- No GraphQL schema change, so the Rust SDL parity gate stays untouched.
- No relay change.
- Writes are gated by `Mydia.Accounts.Authorization.can_update_media?/1`, the same check behind `@can_update_media` on the detail page.
- Every web string goes through `gettext`.
- Fixtures use invented titles only.
- No em dashes in code comments or docs.
- Commit from the worktree with plain `git commit -F <msgfile>` while direnv is loaded, and check each commit with `git show --stat`.

## Review Focus

1. **A folder candidate that is a symlink pointing outside the item's folder.** The expected behavior is that it is not listed and cannot be selected. Pinned in Task 3.
2. **A file uploaded with an image extension but holding other bytes**, such as a `.jpg` that is really HTML. The expected behavior is that it is rejected with `:unsupported_format` and nothing is written. Pinned in Task 2.
3. **A metadata refresh after a custom poster is set.** The expected behavior is that the override survives and the provider's new `poster_path` is stored underneath it. Pinned in Task 2.
4. **A p2p `artwork:` request naming another file in the generated directory**, for example `../avatars/x.png` or `avatar-1.png`. The expected behavior is a 404. Pinned in Task 6.
5. **Deleting a media item that has a hosted poster.** The expected behavior is that the poster file is removed from disk. Pinned in Task 2.

---

### Task 1: Column, resolver and URL passthrough

**Files:**
- Create: `priv/repo/migrations/<real timestamp>_add_poster_override_to_media_items.exs`
- Modify: `lib/mydia/media/media_item.ex` (field and `poster_override_changeset/2`)
- Create: `lib/mydia/media/posters.ex` (only `effective_path/1` in this task)
- Modify: `lib/mydia/metadata/image_url.ex`
- Test: `test/mydia/media/posters_test.exs`, `test/mydia/metadata/image_url_test.exs`

**Interfaces:**
- Produces:
  - `MediaItem` field `:poster_override, :string`
  - `MediaItem.poster_override_changeset(MediaItem.t(), %{poster_override: String.t() | nil}) :: Ecto.Changeset.t()`, which casts only `:poster_override`
  - `Mydia.Media.Posters.effective_path(MediaItem.t() | map()) :: String.t() | nil`

- [ ] **Step 1: Write the failing tests**

```elixir
# posters_test.exs
describe "effective_path/1" do
  test "the override wins over metadata" do
    item = media_item_fixture(%{metadata: %{poster_path: "/provider.jpg"}})
    {:ok, item} = Repo.update(MediaItem.poster_override_changeset(item, %{poster_override: "/chosen.jpg"}))
    assert Posters.effective_path(item) == "/chosen.jpg"
  end

  test "nil override falls back to metadata.poster_path" do
    item = media_item_fixture(%{metadata: %{poster_path: "/provider.jpg"}})
    assert Posters.effective_path(item) == "/provider.jpg"
  end

  test "no override and no metadata is nil" do
    assert Posters.effective_path(%MediaItem{poster_override: nil, metadata: nil}) == nil
  end
end

# image_url_test.exs
test "a hosted poster path passes through untouched" do
  assert ImageUrl.poster_url("/generated/posters/abc-0123abcd.jpg") == "/generated/posters/abc-0123abcd.jpg"
  assert ImageUrl.poster_url("/generated/posters/abc-0123abcd.jpg", "w342") == "/generated/posters/abc-0123abcd.jpg"
end
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `./dev mix test test/mydia/media/posters_test.exs test/mydia/metadata/image_url_test.exs`

Expected: FAIL. `Posters` is undefined, and the passthrough assertion gets a `https://image.tmdb.org/...` URL.

- [ ] **Step 3: Implement**

The migration is a plain `alter table(:media_items), do: add(:poster_override, :text)`. That works on both adapters, so it needs no adapter branch.

Add an `image_url("/generated/" <> _ = path, _size)` clause above the TMDB clause. `effective_path/1` reads `poster_override` first, then `MetadataAccess.get_field(item, :poster_path)`, and treats `""` as nil.

- [ ] **Step 4: Run the tests and confirm they pass**

Run the same command. Also run `./dev mix test test/mydia/repo/migrations/no_varchar_columns_test.exs`.

Expected: PASS.

- [ ] **Step 5: Commit**

Message: `feat(media): poster_override column and effective poster resolver`

---

### Task 2: Poster writes: provider, upload, reset, deletion

**Files:**
- Modify: `lib/mydia/media/posters.ex`
- Create: `lib/mydia/media/poster_store.ex` (the filesystem side: dir, write, delete, format detection)
- Modify: `lib/mydia/media/deletion.ex` (`delete_media_item/3`, `delete_media_items/3`: remove the hosted file after commit)
- Test: `test/mydia/media/posters_test.exs`, `test/mydia/media/poster_store_test.exs`

**Interfaces:**
- Consumes: Task 1's `poster_override_changeset/2` and `effective_path/1`.
- Produces:
  - `PosterStore.storage_dir() :: Path.t()`, which is `Path.join(GeneratedMedia.base_path(), "posters")`
  - `PosterStore.detect_format(binary()) :: {:ok, "jpg" | "png" | "webp"} | {:error, :unsupported_format}`
  - `PosterStore.write(media_item_id :: String.t(), binary()) :: {:ok, url_path :: String.t()} | {:error, :unsupported_format | :too_large | File.posix()}`
  - `PosterStore.delete(url_path :: String.t() | nil) :: :ok`, which only removes `/generated/posters/<basename>` and is a no-op for anything else
  - `PosterStore.hosted?(String.t() | nil) :: boolean()`
  - `PosterStore.path_for(filename :: String.t()) :: {:ok, Path.t()} | {:error, :not_found}`, which applies the Global Constraints regex and checks the file exists (Task 6 uses it)
  - `Posters.set_provider_poster(Scope.t(), MediaItem.t(), String.t()) :: {:ok, MediaItem.t()} | {:error, term()}`
  - `Posters.set_uploaded_poster(Scope.t(), MediaItem.t(), binary()) :: {:ok, MediaItem.t()} | {:error, term()}`
  - `Posters.reset_poster(Scope.t(), MediaItem.t()) :: {:ok, MediaItem.t()} | {:error, term()}`

- [ ] **Step 1: Write the failing tests**

`poster_store_test.exs` sets `:generated_media_path` to a tmp dir with `Application.put_env` in setup and restores it in `on_exit`. That needs `async: false`; see `test/README.md` on global env.

```elixir
@png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0::64>>
@jpg <<0xFF, 0xD8, 0xFF, 0xE0, 0::64>>
@webp "RIFF" <> <<0::32>> <> "WEBPVP8 " <> <<0::64>>

test "detect_format reads magic bytes, not names" do
  assert PosterStore.detect_format(@png) == {:ok, "png"}
  assert PosterStore.detect_format(@jpg) == {:ok, "jpg"}
  assert PosterStore.detect_format(@webp) == {:ok, "webp"}
  assert PosterStore.detect_format("<html>not an image</html>") == {:error, :unsupported_format}
end

test "write names the file <id>-<sha8>.<ext> and rejects oversize" do
  id = Ecto.UUID.generate()
  {:ok, "/generated/posters/" <> name} = PosterStore.write(id, @png)
  assert name =~ ~r/^#{id}-[0-9a-f]{8}\.png$/
  assert File.exists?(Path.join(PosterStore.storage_dir(), name))
  assert PosterStore.write(id, @png <> :binary.copy(<<0>>, 10_000_000)) == {:error, :too_large}
end

test "delete ignores paths outside the posters dir" do
  assert PosterStore.delete("/generated/avatars/avatar-1.png") == :ok
  assert PosterStore.delete("/abc.jpg") == :ok
end
```

```elixir
# posters_test.exs (same tmp-dir setup)
test "upload stores a hosted override; replacing deletes the previous file" do
  item = media_item_fixture()
  {:ok, item} = Posters.set_uploaded_poster(Scope.unrestricted(), item, @png)
  first = item.poster_override
  assert PosterStore.hosted?(first)
  {:ok, item} = Posters.set_uploaded_poster(Scope.unrestricted(), item, @jpg)
  refute File.exists?(disk_path(first))
  assert Posters.effective_path(item) == item.poster_override
end

test "a non-image upload is rejected and nothing is written" do
  item = media_item_fixture()
  assert {:error, :unsupported_format} = Posters.set_uploaded_poster(Scope.unrestricted(), item, "<html>")
  assert Repo.reload!(item).poster_override == nil
  assert File.ls!(PosterStore.storage_dir()) == []
end

test "provider poster replaces a hosted one and deletes its file" do
  item = media_item_fixture()
  {:ok, item} = Posters.set_uploaded_poster(Scope.unrestricted(), item, @png)
  hosted = item.poster_override
  {:ok, item} = Posters.set_provider_poster(Scope.unrestricted(), item, "/alt.jpg")
  assert item.poster_override == "/alt.jpg"
  refute File.exists?(disk_path(hosted))
end

test "reset clears the override and the file" do
  item = media_item_fixture(%{metadata: %{poster_path: "/provider.jpg"}})
  {:ok, item} = Posters.set_uploaded_poster(Scope.unrestricted(), item, @png)
  hosted = item.poster_override
  {:ok, item} = Posters.reset_poster(Scope.unrestricted(), item)
  assert item.poster_override == nil
  assert Posters.effective_path(item) == "/provider.jpg"
  refute File.exists?(disk_path(hosted))
end

test "a metadata refresh keeps the override" do
  item = media_item_fixture(%{metadata: %{poster_path: "/old.jpg"}})
  {:ok, item} = Posters.set_provider_poster(Scope.unrestricted(), item, "/chosen.jpg")
  {:ok, item} = Media.update_media_item(Scope.unrestricted(), item, %{metadata: %{poster_path: "/new.jpg"}})
  assert item.poster_override == "/chosen.jpg"
  assert Posters.effective_path(item) == "/chosen.jpg"
end

test "deleting the item removes its hosted poster" do
  item = media_item_fixture()
  {:ok, item} = Posters.set_uploaded_poster(Scope.unrestricted(), item, @png)
  {:ok, _, _} = Media.delete_media_item(Scope.unrestricted(), item)
  refute File.exists?(disk_path(item.poster_override))
end
```

`disk_path/1` is a test helper: `Path.join(PosterStore.storage_dir(), Path.basename(url))`.

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `./dev mix test test/mydia/media/posters_test.exs test/mydia/media/poster_store_test.exs`

Expected: FAIL, because the functions are undefined.

- [ ] **Step 3: Implement**

- **Writes:** each setter builds `poster_override_changeset` and calls `ItemWrites.persist_and_audit_media_item(changeset, item, actor_type: :user, actor_id: scope.user && scope.user.id, reason: "Poster changed")`, so the usual `Events.media_item_updated` broadcast fires. Only after a successful update does it call `PosterStore.delete(previous)` when the previous value was hosted and differs from the new one.
- **Write failures:** on an update failure for an upload, delete the file just written.
- **Size check:** `PosterStore.write` checks `byte_size > 10_000_000` before detecting the format.
- **Deletion:** in `Deletion`, call `PosterStore.delete(item.poster_override)` after the transaction commits, in both functions. For `delete_media_items/3`, select the overrides before the delete.

- [ ] **Step 4: Run the tests and confirm they pass**

Run the same command, plus `./dev mix test test/mydia/media/deletion_test.exs` if that file exists.

Expected: PASS.

- [ ] **Step 5: Commit**

Message: `feat(media): set, upload and reset custom posters`

---

### Task 3: Posters from the item's folder

**Files:**
- Modify: `lib/mydia/media/posters.ex`
- Test: `test/mydia/media/posters_library_test.exs` (local), plus an `@moduletag :s3` case in the same file using `Mydia.S3Helpers`, the way `test/mydia/p2p/server_storage_stream_test.exs` does

**Interfaces:**
- Consumes: `Posters.set_uploaded_poster/3` (Task 2), `Mydia.Storage.location/1`, `Mydia.Storage.Location.child/2`, `Mydia.Storage.list/1`, `Mydia.Storage.source/2`, `Mydia.Storage.read_range/3` and `Mydia.Storage.stat/1`.
- Produces:
  - `%Mydia.Media.Posters.Candidate{library_path_id: String.t(), relative_path: String.t(), name: String.t(), size: non_neg_integer()}`
  - `Posters.list_library_poster_candidates(MediaItem.t()) :: [Candidate.t()]`
  - `Posters.read_candidate(MediaItem.t(), library_path_id :: String.t(), relative_path :: String.t()) :: {:ok, binary()} | {:error, :not_found | :too_large}`
  - `Posters.set_poster_from_library_file(Scope.t(), MediaItem.t(), library_path_id :: String.t(), relative_path :: String.t()) :: {:ok, MediaItem.t()} | {:error, term()}`

- [ ] **Step 1: Write the failing tests**

The setup is a tmp library root holding:
- `Some Film (2001)/film.mkv` (a media file row)
- `Some Film (2001)/poster.jpg` (JPEG magic bytes)
- `Some Film (2001)/fanart.png`
- `Some Film (2001)/notes.txt`
- `Some Film (2001)/link.jpg`, a symlink to `/etc/hostname`

For a TV show: `Show Name/Season 01/e01.mkv`, `Show Name/poster.png`, `Show Name/Season 01/season01-poster.jpg`.

```elixir
test "movie: image files in the media file's folder, poster/folder/cover first, no symlinks or non-images" do
  names = item |> Posters.list_library_poster_candidates() |> Enum.map(& &1.name)
  assert names == ["poster.jpg", "fanart.png"]
end

test "tv show: images at the show root, not inside season folders" do
  assert show |> Posters.list_library_poster_candidates() |> Enum.map(& &1.name) == ["poster.png"]
end

test "selecting a candidate copies it into the poster store" do
  [c | _] = Posters.list_library_poster_candidates(item)
  {:ok, item} = Posters.set_poster_from_library_file(Scope.unrestricted(), item, c.library_path_id, c.relative_path)
  assert PosterStore.hosted?(item.poster_override)
end

test "a path that is not a listed candidate is refused" do
  for rel <- ["../../etc/hostname", "/etc/hostname", "Some Film (2001)/link.jpg", "Some Film (2001)/notes.txt"] do
    assert {:error, :not_found} = Posters.set_poster_from_library_file(Scope.unrestricted(), item, lp.id, rel)
  end
end

@tag :s3
test "an S3 library's poster is listed and copied" do
  # put film.mkv and poster.jpg under a unique S3 location; the media file row points at it
  assert [%{name: "poster.jpg"} = c] = Posters.list_library_poster_candidates(item)
  assert {:ok, _} = Posters.set_poster_from_library_file(Scope.unrestricted(), item, c.library_path_id, c.relative_path)
end
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `./dev mix test test/mydia/media/posters_library_test.exs`

Expected: FAIL, because the functions are undefined.

- [ ] **Step 3: Implement**

- **Which folders:** preload `media_files: :library_path` for a movie and `episodes: [media_files: :library_path]` for a show.
  - A movie's folder is `Path.dirname(relative_path)` of each file.
  - A show's folder is its episode file's dirname, moved up one level when that dirname's basename matches `~r/^(season|series|specials|s\d+)/i`.
  - Deduplicate by `{library_path_id, dir}`.
- **Listing:** `Storage.list(Location.child(loc, dir))`. Keep only top-level entries (no `/` in the entry's relative path), with extensions `.jpg .jpeg .png .webp`, case-insensitive. On local storage, drop entries whose `File.lstat` type is `:symlink`.
- **Sorting:** names starting with `poster.`, `folder.` or `cover.` first, in that order, then alphabetical.
- **Reading and selecting:** `read_candidate` and `set_poster_from_library_file` accept only an exact `{library_path_id, relative_path}` member of `list_library_poster_candidates/1`. Anything else is `{:error, :not_found}`. That one rule covers traversal, absolute paths and symlinks. Bytes are read with `Storage.read_range(source, 0, size)` after checking `size <= 10_000_000`.

- [ ] **Step 4: Run the tests and confirm they pass**

Run the same command. Also run `./dev mix test --only s3 test/mydia/media/posters_library_test.exs` when the S3 test service is up; see `test/README.md`.

Expected: PASS.

- [ ] **Step 5: Commit**

Message: `feat(media): choose a poster file from the item's folder`

---

### Task 4: Route every media-item poster read through the resolver

**Files (modify each line that reads an item's `poster_path`):**
- `lib/mydia_web/live/helpers/media_images.ex:27`
- `lib/mydia_web/schema/resolvers/item_builder.ex:56`
- `lib/mydia_web/schema/resolvers/media_resolver.ex:130`
- `lib/mydia_web/controllers/api/media_controller.ex:344`
- `lib/mydia/playback.ex:643`
- `lib/mydia/streaming.ex:224`
- `lib/mydia/collections.ex:403`
- `lib/mydia/library_search.ex:194,252`
- `lib/mydia/media/calendar.ex:81,146`
- `lib/mydia/plugins/host_functions.ex:806`
- `lib/mydia/plugins/shelves/verifier.ex:187`
- `lib/mydia_web/live/collection_live/show.ex:959`

Tests: `test/mydia_web/live/helpers/media_images_test.exs` and `test/mydia_web/schema/resolvers/item_builder_test.exs`.

**Interfaces:**
- Consumes: `Posters.effective_path/1` (Task 1). At sites holding only the `metadata` map and not the item, pass the item instead. Where only the metadata exists (`item_builder.ex`, `media_resolver.ex`), thread the item through or read `item.poster_override || metadata.poster_path` via `effective_path/1` on the item.

- [ ] **Step 1: Write the failing tests**

```elixir
# media_images_test.exs
test "an override is the poster" do
  item = %MediaItem{poster_override: "/generated/posters/x-0123abcd.png", metadata: %MediaMetadata{poster_path: "/p.jpg"}}
  assert MediaImages.poster_url(item) == "/generated/posters/x-0123abcd.png"
end

test "a provider override becomes a TMDB URL" do
  item = %MediaItem{poster_override: "/alt.jpg", metadata: %MediaMetadata{poster_path: "/p.jpg"}}
  assert MediaImages.poster_url(item, "w342") == "https://image.tmdb.org/t/p/w342/alt.jpg"
end

# item_builder_test.exs
test "posterUrl follows the override" do
  # build the item the way the existing item_builder tests do, with poster_override "/alt.jpg"
  assert built.poster_url == "https://image.tmdb.org/t/p/w500/alt.jpg"
end
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `./dev mix test test/mydia_web/live/helpers/media_images_test.exs test/mydia_web/schema/resolvers/item_builder_test.exs`

Expected: FAIL. The poster is still the metadata path.

- [ ] **Step 3: Replace each read with `Posters.effective_path(item)`**

After editing, `grep -rn "poster_path" lib --include=*.ex` must show no remaining media-item read. Season, episode, collection, franchise, request, discover and search-result reads stay as they are.

- [ ] **Step 4: Run the tests and confirm they pass**

Run the same command, then `./dev mix test test/mydia/playback test/mydia/collections_test.exs test/mydia/library_search_test.exs test/mydia/media/calendar_test.exs test/mydia/plugins test/mydia_web/schema`.

Expected: PASS. A failure there means a site changed shape: fix the call, not the test.

- [ ] **Step 5: Commit**

Message: `feat(media): every poster read honors the override`

---

### Task 5: Relay image listing: language and TVDB posters

`parse_tvdb_artworks/1` (`lib/mydia/metadata/provider/relay.ex:995`) matches only named types. TVDB sends integer type ids (`@tvdb_artwork_type_ids`: poster `2`, background `3`), so today a TVDB series returns no posters.

**Files:**
- Modify: `lib/mydia/metadata/structs/image_data.ex` (add `:language`)
- Modify: `lib/mydia/metadata/provider/relay.ex` (`parse_tvdb_artworks/1`)
- Test: `test/mydia/metadata/provider/relay_images_test.exs` (Bypass)

**Interfaces:**
- Produces: `ImageData.language :: String.t() | nil`. It comes from TMDB `"iso_639_1"` and TVDB `"language"`. TVDB posters are listed for integer type `2`, and for named type `"poster"` as before.

- [ ] **Step 1: Write the failing tests**

```elixir
test "TMDB posters carry their language" do
  Bypass.expect_once(bypass, "GET", "/tmdb/movies/603/images", fn conn ->
    Req.Test.json(conn, %{"posters" => [%{"file_path" => "/a.jpg", "iso_639_1" => "en", "vote_average" => 5.1}], "backdrops" => [], "logos" => []})
  end)
  {:ok, %{posters: [p]}} = Relay.fetch_images_by_ref(config, {:tmdb, 603}, media_type: :movie)
  assert p.language == "en"
end

test "TVDB posters with integer type ids are listed" do
  Bypass.expect_once(bypass, "GET", "/tvdb/series/77/extended", fn conn ->
    Req.Test.json(conn, %{"data" => %{"artworks" => [
      %{"type" => 2, "image" => "https://artworks.thetvdb.com/p.jpg", "language" => "eng"},
      %{"type" => 3, "image" => "https://artworks.thetvdb.com/b.jpg"},
      %{"type" => 1, "image" => "https://artworks.thetvdb.com/banner.jpg"}]}})
  end)
  {:ok, images} = Relay.fetch_images_by_ref(config, {:tvdb, 77}, [])
  assert [%{file_path: "https://artworks.thetvdb.com/p.jpg", language: "eng"}] = images.posters
  assert [%{file_path: "https://artworks.thetvdb.com/b.jpg"}] = images.backdrops
end
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `./dev mix test test/mydia/metadata/provider/relay_images_test.exs`

Expected: FAIL. The language is nil and TVDB posters are `[]`.

- [ ] **Step 3: Implement**

Add the struct field and its `from_api_response` key. In `parse_tvdb_artworks/1`, normalize the type with `@tvdb_artwork_type_ids` so an integer `2` or `3` maps to `"poster"` or `"background"`.

- [ ] **Step 4: Run the tests and confirm they pass**

Run the same file plus `./dev mix test test/mydia/metadata`.

Expected: PASS.

- [ ] **Step 5: Commit**

Message: `fix(metadata): list TVDB posters and carry image language`

---

### Task 6: Serve hosted posters over p2p

**Files:**
- Modify: `lib/mydia/p2p/server.ex` (the `handle_hls_stream/3` `cond` at line ~690, plus a public `@doc false` helper)
- Test: `test/mydia/p2p/server_artwork_test.exs`

**Interfaces:**
- Consumes: `PosterStore.path_for/1` (Task 2).
- Produces: `Mydia.P2p.Server.resolve_artwork("artwork:" <> filename) :: {:ok, Path.t()} | {:error, :not_found}`.
- Wire contract with Task 8: session id `artwork:<filename>`, path `file`.

- [ ] **Step 1: Write the failing tests**

Use the same tmp `:generated_media_path` setup as Task 2, with `async: false`.

```elixir
test "a stored poster resolves to its file" do
  {:ok, "/generated/posters/" <> name} = PosterStore.write(Ecto.UUID.generate(), @png)
  assert {:ok, path} = Server.resolve_artwork("artwork:" <> name)
  assert File.read!(path) == @png
end

test "anything else is not found" do
  for id <- ["artwork:../avatars/avatar-1.png", "artwork:avatar-1.png", "artwork:x-0123abcd.gif",
             "artwork:#{Ecto.UUID.generate()}-0123abcd.png", "artwork:"] do
    assert Server.resolve_artwork(id) == {:error, :not_found}
  end
end
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `./dev mix test test/mydia/p2p/server_artwork_test.exs`

Expected: FAIL, because `resolve_artwork/1` is undefined.

- [ ] **Step 3: Implement**

Add the `String.starts_with?(req.session_id, "artwork:")` branch before the `true ->` fallback, so it sits after the token check that is already there. On `{:ok, path}` it calls `stream_hls_file(resource, stream_id, path, req)`. On `{:error, :not_found}` it calls `HlsResponse.send_error(resource, stream_id, 404, "Not found")`. Keep the branch to those two outcomes, because this function is a bug magnet.

- [ ] **Step 4: Run the tests and confirm they pass**

Run the same file plus `./dev mix test test/mydia/p2p`.

Expected: PASS.

- [ ] **Step 5: Commit**

Message: `feat(p2p): serve hosted posters on an artwork: session`

---

### Task 7: Poster picker on the detail page

**Files:**
- Create: `lib/mydia_web/live/media_live/show/poster_picker.ex` (LiveComponent `MydiaWeb.MediaLive.Show.PosterPicker`)
- Create: `lib/mydia_web/controllers/poster_candidate_controller.ex`
- Modify: `lib/mydia_web/router.ex`: inside the `/admin` scope at line ~278, add `get "/media/:id/poster-candidates/:library_path_id/*path", PosterCandidateController, :show`
- Modify: `lib/mydia_web/live/media_live/show/components.ex:75-83` (the pencil over the poster)
- Modify: `lib/mydia_web/live/media_live/show.ex` (the `open_poster_picker` and `close_poster_picker` events, a `:poster_picker_open` assign, and `handle_info({:poster_changed, item})` reloading `@media_item`)
- Modify: `lib/mydia_web/live/media_live/show.html.heex` (mounts the component next to the `FixMatchModal` mount at line ~495)
- Modify: `priv/gettext/default.pot` and the locale `.po` files, via `./dev mix gettext.extract --merge`
- Test: `test/mydia_web/live/media_live/poster_picker_test.exs`, `test/mydia_web/controllers/poster_candidate_controller_test.exs`

**Interfaces:**
- Consumes:
  - `Posters.set_provider_poster/3`, `set_uploaded_poster/3`, `set_poster_from_library_file/4`, `reset_poster/2`, `list_library_poster_candidates/1` and `read_candidate/3`
  - `Metadata.fetch_images_by_ref/3` with `Metadata.default_relay_config/0`, overridable through the component's `metadata_config` attr so tests can pass a Bypass config
  - `ImageData.language` (Task 5)
- Produces:
  - DOM ids: `#poster-edit-button`, `#poster-picker`, `#poster-tab-browse`, `#poster-tab-upload`, `#poster-tab-folder`, `#poster-option-<n>`, `#poster-upload-form`, `#poster-candidate-<n>`, `#poster-reset`, `#poster-save`, `#poster-browse-error`
  - The component sends `{:poster_changed, MediaItem.t()}` to the parent LiveView.

- [ ] **Step 1: Write the failing tests**

```elixir
test "the pencil shows only for users who can update media" do
  # admin: has_element?(view, "#poster-edit-button"); a read-only user (the existing fixture used for can_update_media? false): refute
end

test "browse lists relay posters and saving one sets the override" do
  # Bypass /tmdb/movies/:id/images with two posters (iso_639_1 "en" and "fr")
  view |> element("#poster-edit-button") |> render_click()
  assert has_element?(view, "#poster-option-1")
  view |> element("#poster-option-1") |> render_click()
  view |> element("#poster-save") |> render_click()
  assert Repo.reload!(item).poster_override == "/second.jpg"
end

test "a relay failure shows the error and the upload tab still works" do
  # Bypass returns 500
  assert has_element?(view, "#poster-browse-error")
  view |> element("#poster-tab-upload") |> render_click()
  assert has_element?(view, "#poster-upload-form")
end

test "uploading a PNG sets a hosted override" do
  upload = file_input(view, "#poster-upload-form", :poster, [%{name: "mine.png", content: @png, type: "image/png"}])
  render_upload(upload, "mine.png")
  view |> element("#poster-save") |> render_click()
  assert Repo.reload!(item).poster_override =~ ~r{^/generated/posters/}
end

test "the folder tab lists candidates and selecting one saves it" do
  view |> element("#poster-tab-folder") |> render_click()
  view |> element("#poster-candidate-0") |> render_click()
  view |> element("#poster-save") |> render_click()
  assert Repo.reload!(item).poster_override =~ ~r{^/generated/posters/}
end

test "reset is offered only with an override, and clears it" do
  refute has_element?(view, "#poster-reset")
  # after setting a provider override and reopening:
  view |> element("#poster-reset") |> render_click()
  assert Repo.reload!(item).poster_override == nil
end
```

```elixir
# poster_candidate_controller_test.exs
test "an admin gets a listed candidate's bytes with its content type"
test "a path that is not a candidate is 404"
test "a non-admin is refused"   # the :require_admin pipeline's existing behavior
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `./dev mix test test/mydia_web/live/media_live/poster_picker_test.exs test/mydia_web/controllers/poster_candidate_controller_test.exs`

Expected: FAIL. The elements and the route don't exist.

- [ ] **Step 3: Implement**

- **Opening:** the component starts the Browse fetch with `start_async` when it opens. TMDB is fetched with `media_type: :movie | :tv_show` from `item.type`, and TVDB too when `item.tvdb_id` is set.
- **Browse results:** sorted by `vote_average` descending, nils last. Each grid tile is labeled with "TMDB"/"TVDB" and the language. Thumbnails use `ImageUrl.poster_url(path, "w185")`.
- **Upload:** `allow_upload(:poster, accept: ~w(.jpg .jpeg .png .webp), max_entries: 1, max_file_size: 10_000_000)`. Bytes are read in `consume_uploaded_entries` with `File.read!`.
- **Folder tab:** thumbnails `src` `~p"/admin/media/#{item.id}/poster-candidates/#{c.library_path_id}/#{c.relative_path}"`.
- **Save:** dispatches on the selected tab. Every handler re-checks `Authorization.can_update_media?(current_user)`. Errors (`:unsupported_format`, `:too_large`, `:not_found`) show as inline daisyUI `alert alert-error` text using gettext copy.
- **Pencil:** a `btn btn-circle btn-sm` absolutely positioned at the poster's top-right. It shows on hover and focus (`opacity-0 group-hover:opacity-100 focus:opacity-100`) and is always visible on touch (`[@media(hover:none)]:opacity-100`). It is wrapped in `:if={@can_update_media}`, and that assign has to be passed into the sidebar component.
- **Controller:** calls `Posters.read_candidate/3` and replies with the content type from `PosterStore.detect_format/1` and `cache-control: private, max-age=60`.

- [ ] **Step 4: Run the tests and confirm they pass**

Run the same command plus `./dev mix test test/mydia_web/live/media_live`.

Expected: PASS.

- [ ] **Step 5: Check it in a browser**

Run `./dev up -d` and log in as admin. Open a movie, use the pencil, and try each tab, including Reset. Confirm that the library grid shows the new poster without a page reload.

- [ ] **Step 6: Commit**

Message: `feat(web): poster picker on the media detail page`

---

### Task 8: Player loads hosted posters (HTTP and p2p)

**Files:**
- Modify: `player/lib/core/p2p/media_route.dart`
- Modify: `player/lib/core/sources/mydia/mydia_source.dart:341` (`artwork`)
- Test: `player/test/core/p2p/media_route_artwork_test.dart`, `player/test/core/sources/mydia/mydia_artwork_test.dart`; update `mydia_source_test.dart:205` to keep its `/relative.jpg` → null assertion

**Interfaces:**
- Consumes: the wire contract from Task 6 (session `artwork:<file>`, path `file`).
- Produces:
  - `MediaRoutes.artworkSessionPrefix = 'artwork:'`
  - `MediaRoutes.artwork(String base, String file) => '$base/artwork/$file'`
  - `resolve('/artwork/<file>')` returns `MediaRouteMatch(sessionId: 'artwork:<file>', path: 'file', kind: MediaRouteKind.hls)`

- [ ] **Step 1: Write the failing tests**

```dart
// media_route_artwork_test.dart
test('an artwork URL round-trips to its session', () {
  final url = MediaRoutes.artwork('http://127.0.0.1:9/t/acc', 'abc-0123abcd.png');
  expect(url, 'http://127.0.0.1:9/t/acc/artwork/abc-0123abcd.png');
  final m = MediaRoutes.resolve('/artwork/abc-0123abcd.png') as MediaRouteMatch;
  expect(m.sessionId, 'artwork:abc-0123abcd.png');
  expect(m.path, 'file');
  expect(m.kind, MediaRouteKind.hls);
});

test('an artwork path with no file is a 400', () {
  expect((MediaRoutes.resolve('/artwork/') as MediaRouteFailure).statusCode, 400);
});
```

```dart
// mydia_artwork_test.dart, modeled on mydia_downloadable_test.dart (LocalProxyService.forTesting())
const hosted = ArtworkRef('/generated/posters/abc-0123abcd.png');

test('over HTTP a hosted poster is the server URL plus its path, no header', () async {
  final s = source(const MydiaCredentials(instanceId: 'i', accessToken: 'a', serverUrl: 'https://media.example/'));
  final req = await s.artwork(hosted, width: 300);
  expect(req!.url, 'https://media.example/generated/posters/abc-0123abcd.png');
  expect(req.headers, isEmpty);
});

test('over p2p a hosted poster goes through the proxy artwork route', () async {
  final s = source(const MydiaCredentials(instanceId: 'i', accessToken: 'a', nodeAddr: '{"id":"abc"}'));
  final req = await s.artwork(hosted, width: 300);
  expect(req!.url, MediaRoutes.artwork(proxy.targetBaseUrl('mguest'), 'abc-0123abcd.png'));
  expect(proxy.isRunning, isTrue);
});

test('other relative paths are still refused', () async {
  expect(await source(httpCreds).artwork(const ArtworkRef('/relative.jpg'), width: 300), isNull);
  expect(await source(httpCreds).artwork(const ArtworkRef('/generated/avatars/a.png'), width: 300), isNull);
});
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `./dev flutter test --concurrency=1 test/core/p2p/media_route_artwork_test.dart test/core/sources/mydia/mydia_artwork_test.dart` (from `player/`, after `./dev player setup`).

Expected: FAIL. `MediaRoutes.artwork` is undefined and `artwork` returns null.

- [ ] **Step 3: Implement**

- **Route:** add an `/artwork/` branch to `resolve`. It doesn't fit `_byteStream`, because the file name is the only segment.
- **`artwork`:** keep the absolute case. Then, only for paths starting with `/generated/posters/`, load `client.credentials()`:
  - p2p: set `_holdsProxy = true`, then `mydiaProxyBase(_proxy(), credentials, owner: this, target: source.account.id)` and `MediaRoutes.artwork(base, file)`.
  - Otherwise: `serverUrl` with trailing slashes stripped, plus the path.
  - `cacheKey` stays `'${id.value}|${art.path}|$width'`.
- **Docs:** update the doc comment on `absoluteArtworkRequest` to say hosted posters are the one exception, handled in `artwork`.

- [ ] **Step 4: Run the tests and confirm they pass**

Run the same command, then `./dev player test`.

Expected: PASS.

- [ ] **Step 5: Commit**

Message: `feat(player): load hosted posters over HTTP and p2p`

---

### Task 9: Docs, co-change check, precommit

**Files:**
- Modify: `lib/mydia/media/README.md` (a short "Posters" section: the override column, effective poster resolution, the hosted file lifecycle, folder files copied once)

- [ ] **Step 1: Write the README section**

Cover what a future editor would trip on:
- Refresh never touches `poster_override`.
- New poster reads must go through `Posters.effective_path/1`.
- Hosted files are named `<id>-<sha8>.<ext>`, and the p2p regex depends on that shape.

- [ ] **Step 2: Check co-change partners**

Run `mcp__repowise__get_risk` with `changed_files` set to the output of `git diff --name-only origin/master...`. For each entry in `missing_cochanges`, either touch the file or note in the PR why it doesn't apply. `server/crates/api/src/types/media.rs` co-changes with `item_builder.ex`, but the GraphQL shape is unchanged, so it does not apply.

- [ ] **Step 3: Run precommit**

Run `./dev mix precommit`. It can run past the 600s Bash cap, so run the suite in foreground chunks if needed. Expected: no failures, no warnings, formatter clean.

- [ ] **Step 4: Commit**

Message: `docs(media): custom posters in the media README`
