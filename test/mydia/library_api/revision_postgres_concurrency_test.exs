defmodule Mydia.LibraryApi.RevisionPostgresConcurrencyTest do
  @moduledoc """
  Proves a late writer still delivers its transition when PostgreSQL hands out
  identity values out of commit order.

  An identity sequence is not transactional: a transaction can allocate a
  revision, be delayed, and then apply it after another transaction already
  committed a later one. The conflict update's greater-revision guard keeps the
  marker monotonic, and a rejected attempt allocates a fresh revision and
  retries, so a consumer already past the earlier commit still observes the
  late transition. Discarding that attempt would drop it, deletion flag
  included.

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
    alias Mydia.LibraryApi.RevisionFeed
    alias Mydia.Repo

    @barrier_timeout 30_000
    @next_revision """
    SELECT nextval(pg_get_serial_sequence('media_item_revisions', 'revision')::regclass)
    """

    test "a delayed live revision is delivered past the higher committed marker" do
      assert_delayed_revision_delivered(false)
    end

    test "a delayed deletion is delivered as a tombstone past the higher committed marker" do
      assert_delayed_revision_delivered(true)
    end

    # A allocates `low` and holds it. B then reserves the next real identity
    # value and commits a live marker there, ahead of A by one sequence step.
    # The feed is read while A is still blocked, so a consumer can already be
    # past B. When A commits, its retried revision must exceed B, one marker
    # remains, and polling strictly after B returns that transition.
    defp assert_delayed_revision_delivered(deleted) do
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
              low = scalar!(@next_revision)

              send(parent, {:allocated, self(), low})

              receive do
                {:apply_stale, ^ref} -> :ok
              after
                @barrier_timeout -> raise "the delayed writer was never released"
              end

              Repo.query!(
                "SELECT mydia_library_revision_apply($1::text::uuid, $2, $3)",
                [item_id, low, deleted]
              )
            end)
          after
            Sandbox.checkin(Repo)
          end
        end)

      delayed_pid = delayed.pid
      assert_receive {:allocated, ^delayed_pid, low}, @barrier_timeout

      # Reserve the next identity value and commit B's live marker on it. A
      # synthetic gap is not required: one real allocation puts the stored
      # revision ahead of the value A is holding.
      high =
        unboxed(fn ->
          reserved = scalar!(@next_revision)

          Repo.query!(
            "SELECT mydia_library_revision_apply($1::text::uuid, $2, false)",
            [item_id, reserved]
          )

          scalar!(
            "SELECT revision FROM media_item_revisions WHERE media_item_id = $1::text::uuid",
            [item_id]
          )
        end)

      assert high > low

      # A consumer can observe B and resume strictly after it before A lands.
      before_release =
        unboxed(fn ->
          RevisionFeed.list(limit: 200, after: high)
        end)

      refute Enum.any?(before_release, &(&1.media_item_id == item_id))

      send(delayed_pid, {:apply_stale, ref})
      assert {:ok, _} = Task.await(delayed, @barrier_timeout)

      unboxed(fn ->
        count =
          scalar!(
            "SELECT count(*) FROM media_item_revisions WHERE media_item_id = $1::text::uuid",
            [item_id]
          )

        revision =
          scalar!(
            "SELECT revision FROM media_item_revisions WHERE media_item_id = $1::text::uuid",
            [item_id]
          )

        delivered =
          RevisionFeed.list(limit: 200, after: high)
          |> Enum.filter(&(&1.media_item_id == item_id))

        assert count == 1
        assert revision > high

        assert [%{revision: ^revision, deleted: ^deleted}] = delivered
      end)
    end

    defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

    defp scalar!(sql, params \\ []) do
      %{rows: [[value]]} = Repo.query!(sql, params)
      value
    end
  end
end
