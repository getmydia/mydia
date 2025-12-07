defmodule Mydia.Jobs.ImportSessionCleanupTest do
  use Mydia.DataCase, async: true
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Jobs.ImportSessionCleanup
  alias Mydia.Library

  import Mydia.AccountsFixtures

  describe "perform/1" do
    test "successfully completes with no import sessions" do
      assert :ok = perform_job(ImportSessionCleanup, %{})
    end

    test "deletes expired import sessions" do
      user = user_fixture()

      # Create a session
      {:ok, session} =
        Library.create_import_session(%{
          user_id: user.id
        })

      # Manually set expires_at to 2 days ago (expired)
      import Ecto.Query
      expired_at = DateTime.add(DateTime.utc_now(), -2, :day) |> DateTime.truncate(:second)

      from(s in Library.ImportSession, where: s.id == ^session.id)
      |> Mydia.Repo.update_all(set: [expires_at: expired_at])

      # Run the cleanup job
      assert :ok = perform_job(ImportSessionCleanup, %{})

      # Session should be deleted
      assert is_nil(Library.get_import_session(session.id))
    end

    test "keeps non-expired sessions" do
      user = user_fixture()

      # Create a session (default expiry is 24 hours in the future)
      {:ok, session} =
        Library.create_import_session(%{
          user_id: user.id
        })

      # Run the cleanup job
      assert :ok = perform_job(ImportSessionCleanup, %{})

      # Session should still exist
      assert Library.get_import_session(session.id) != nil
    end

    test "deletes old completed sessions" do
      user = user_fixture()

      # Create a session
      {:ok, session} =
        Library.create_import_session(%{
          user_id: user.id
        })

      # Mark it as completed and set completed_at to 10 days ago
      import Ecto.Query
      past = DateTime.add(DateTime.utc_now(), -10, :day) |> DateTime.truncate(:second)

      from(s in Library.ImportSession, where: s.id == ^session.id)
      |> Mydia.Repo.update_all(set: [status: "completed", completed_at: past])

      # Run the cleanup job
      assert :ok = perform_job(ImportSessionCleanup, %{})

      # Old completed session should be deleted
      assert is_nil(Library.get_import_session(session.id))
    end

    test "keeps recent completed sessions" do
      user = user_fixture()

      # Create a session and mark it as completed
      {:ok, session} =
        Library.create_import_session(%{
          user_id: user.id
        })

      # Mark it as completed with completed_at set to now (within 7 day retention)
      import Ecto.Query
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      from(s in Library.ImportSession, where: s.id == ^session.id)
      |> Mydia.Repo.update_all(set: [status: "completed", completed_at: now])

      # Run the cleanup job
      assert :ok = perform_job(ImportSessionCleanup, %{})

      # Recent completed session should still exist
      assert Library.get_import_session(session.id) != nil
    end
  end
end
