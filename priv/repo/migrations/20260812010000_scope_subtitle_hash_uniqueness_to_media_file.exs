defmodule Mydia.Repo.Migrations.ScopeSubtitleHashUniquenessToMediaFile do
  @moduledoc """
  Two rips of the same movie (a 1080p and a 4K, say) legitimately produce the
  same `subtitle_hash` when a subtitle provider matches them to the same
  underlying subtitle file. `Downloader.check_duplicate/2` is being scoped to
  `{media_file_id, subtitle_hash}` so a download for the second file is no
  longer treated as a duplicate of the first file's row -- but the original
  migration (20251116022802) put a *global* unique index on `subtitle_hash`
  alone, which would reject that second row's insert regardless of what the
  application-level lookup decides. This replaces it with a composite unique
  index so uniqueness is enforced per media file, matching the query.

  Portable across both adapters: index create/drop is plain DDL, no adapter
  branching needed.
  """

  use Ecto.Migration

  def change do
    drop unique_index(:subtitles, [:subtitle_hash])
    create unique_index(:subtitles, [:media_file_id, :subtitle_hash])
  end
end
