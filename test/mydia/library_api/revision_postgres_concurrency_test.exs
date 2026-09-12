defmodule Mydia.LibraryApi.RevisionPostgresConcurrencyTest do
  @moduledoc """
  Proves the marker upsert keeps the greatest revision when PostgreSQL hands out
  values out of commit order.

  An identity sequence is not transactional: a transaction can allocate a
  revision, be delayed, and then apply it after another transaction already
  committed a later one. Without the conflict update's
  `WHERE media_item_revisions.revision < EXCLUDED.revision` guard, that delayed
  write would move the marker backwards, and a polling consumer that had already
  passed the newer revision would never see the item again.

  SQLite cannot express this shape: its `INTEGER PRIMARY KEY AUTOINCREMENT`
  values are allocated inside the write lock, in commit order. The case is
  therefore compiled for PostgreSQL only, matching
  `test/mydia/repo/migrations/no_varchar_columns_test.exs`.

  Both writers run on real, unsandboxed connections so the transactions really
  interleave; the test process drives the barrier for them.
  """

  use Mydia.DataCase, async: false

  if Mydia.Repo.__adapter__() == Ecto.Adapters.Postgres do
    alias Ecto.Adapters.SQL.Sandbox
    alias Mydia.Repo

    @barrier_timeout 30_000

    test "a lower revision allocated before a higher one commits cannot overwrite it" do
      item_id = Ecto.UUID.generate()

      # Every `$n` bound to a uuid position is cast from text explicitly. An
      # uncast parameter there is described as uuid, and Postgrex encodes that
      # type from a 16-byte binary only, never from the 36-character string
      # `Ecto.UUID.generate/0` returns. This is the same cast
      # `RevisionFeed.mark_live/1` uses for the same reason.
      on_exit(fn ->
        unboxed(fn ->
          Repo.query!(
            "DELETE FROM media_item_revisions WHERE media_item_id = $1::text::uuid",
            [item_id]
          )
        end)
      end)

      # The marker must already exist, so both writers resolve the unique
      # conflict through the update branch rather than inserting. The revision
      # itself is not asserted: `nextval` is non-transactional, so the identity
      # sequence is shared with every other test that wrote a media item and its
      # position is not this test's to predict. Reading a row back is what proves
      # the marker was written.
      baseline =
        unboxed(fn ->
          Repo.query!(
            "SELECT mydia_mark_media_item_changed($1::text::uuid, false)",
            [item_id]
          )

          scalar!(
            "SELECT revision FROM media_item_revisions WHERE media_item_id = $1::text::uuid",
            [item_id]
          )
        end)

      assert is_integer(baseline)

      parent = self()
      ref = make_ref()

      delayed =
        Task.async(fn ->
          Sandbox.checkout(Repo, sandbox: false)

          try do
            Repo.transaction(fn ->
              # Every trigger allocates its revision from this sequence before
              # the conflict resolves. Allocating here and holding it open is
              # exactly a transaction whose write lands late.
              low =
                scalar!(
                  "SELECT nextval(pg_get_serial_sequence('media_item_revisions', 'revision')::regclass)"
                )

              send(parent, {:allocated, self(), low})

              receive do
                {:apply_stale, ^ref} -> :ok
              after
                @barrier_timeout -> raise "the delayed writer was never released"
              end

              Repo.query!(
                "SELECT mydia_library_revision_apply($1::text::uuid, $2, false)",
                [item_id, low]
              )
            end)
          after
            Sandbox.checkin(Repo)
          end
        end)

      delayed_pid = delayed.pid
      assert_receive {:allocated, ^delayed_pid, low}, @barrier_timeout

      high =
        unboxed(fn ->
          Repo.query!(
            "SELECT mydia_mark_media_item_changed($1::text::uuid, false)",
            [item_id]
          )

          scalar!(
            "SELECT revision FROM media_item_revisions WHERE media_item_id = $1::text::uuid",
            [item_id]
          )
        end)

      assert high > low

      send(delayed_pid, {:apply_stale, ref})
      Task.await(delayed, @barrier_timeout)

      final =
        unboxed(fn ->
          scalar!(
            "SELECT revision FROM media_item_revisions WHERE media_item_id = $1::text::uuid",
            [item_id]
          )
        end)

      assert final == high,
             "the delayed write replayed revision #{low} over the committed revision #{high}"
    end

    defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

    defp scalar!(sql, params \\ []) do
      %{rows: [[value]]} = Repo.query!(sql, params)
      value
    end
  end
end
