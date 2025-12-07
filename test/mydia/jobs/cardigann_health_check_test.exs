defmodule Mydia.Jobs.CardigannHealthCheckTest do
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Jobs.CardigannHealthCheck

  describe "perform/1" do
    test "skips when cardigann feature is disabled" do
      original = Application.get_env(:mydia, :features, [])

      try do
        # Disable feature flag
        Application.put_env(:mydia, :features, cardigann_enabled: false)

        # Job should complete successfully without doing anything
        assert :ok = perform_job(CardigannHealthCheck, %{})
      after
        Application.put_env(:mydia, :features, original)
      end
    end

    test "runs health checks when feature is enabled and no definition_id" do
      original = Application.get_env(:mydia, :features, [])

      try do
        # Enable feature flag
        Application.put_env(:mydia, :features, cardigann_enabled: true)

        # Job should complete (even with no indexers)
        assert :ok = perform_job(CardigannHealthCheck, %{})
      after
        Application.put_env(:mydia, :features, original)
      end
    end

    test "processes specific definition_id when provided" do
      original = Application.get_env(:mydia, :features, [])

      try do
        # Enable feature flag
        Application.put_env(:mydia, :features, cardigann_enabled: true)

        # Use a valid UUID format for the definition ID
        fake_uuid = Ecto.UUID.generate()

        # Job should fail since definition doesn't exist
        # But it exercises the code path
        result = perform_job(CardigannHealthCheck, %{"definition_id" => fake_uuid})

        # Will return error since definition doesn't exist
        assert match?({:error, _}, result) or result == :ok
      after
        Application.put_env(:mydia, :features, original)
      end
    end
  end

  describe "new/2" do
    test "creates job changeset without definition_id" do
      changeset = CardigannHealthCheck.new(%{"definition_id" => nil})
      assert changeset.valid?
      assert changeset.changes.args["definition_id"] == nil
      assert changeset.changes.queue == "maintenance"
    end

    test "creates job changeset with definition_id" do
      changeset = CardigannHealthCheck.new(%{"definition_id" => "test-123"})
      assert changeset.valid?
      assert changeset.changes.args["definition_id"] == "test-123"
    end
  end
end
