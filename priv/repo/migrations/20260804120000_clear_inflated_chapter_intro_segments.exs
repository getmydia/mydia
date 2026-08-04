defmodule Mydia.Repo.Migrations.ClearInflatedChapterIntroSegments do
  use Ecto.Migration

  # A chapter's end_time is where the *next* chapter begins, not where the
  # named thing stops. Releases that mark only structural points therefore gave
  # their opening chapter a span running all the way to the credits. Bluey
  # ships two chapters per episode, Intro and Credits, so every episode stored
  # an intro covering 96% of its runtime and a Skip Intro button that jumped to
  # 7:00 of 7:18.
  #
  # `SegmentDetection.Chapters` now bounds a chapter-derived intro, but rows
  # written before that rule are still stored and still drive the button. This
  # clears the ones the rule would reject and returns their files to the
  # pending backlog, which is what the per-season Re-analyze button already
  # does. Nothing here is user data: segments are derived, and the detector
  # rebuilds them on the scheduler's next tick.
  #
  # Only the intro rows are touched. A credits chapter runs to the next marker
  # or to EOF, and both are where the credits genuinely end, so that side was
  # never inflated. Across 389 chapter-derived credits rows in a production
  # library none had an implausible span, against 128 of 402 intros.
  #
  # The bound applied here is the absolute 180s with no runtime term. Runtime
  # lives in media_files.metadata as JSON, and reading it would need
  # adapter-specific JSON SQL for SQLite and Postgres. Measured against that
  # same library the two rules select exactly the same rows, because an intro
  # long enough to swallow an episode is far past 180s either way.
  @max_intro_ms 180_000

  @condition """
  source = 'chapters' AND type = 'intro' AND (end_ms - start_ms) > #{@max_intro_ms}
  """

  def up do
    # The update runs first: it reads the subquery that the delete then empties.
    execute("""
    UPDATE media_files
    SET segment_analysis_state = 'pending',
        segment_analysis_attempts = 0,
        last_segment_analysis_error = NULL,
        segments_analyzed_at = NULL
    WHERE id IN (SELECT media_file_id FROM media_segments WHERE #{@condition})
    """)

    execute("DELETE FROM media_segments WHERE #{@condition}")
  end

  # Irreversible by design. The rows removed here were wrong, and re-inserting
  # them would restore the bug.
  def down, do: :ok
end
