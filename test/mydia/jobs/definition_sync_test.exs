defmodule Mydia.Jobs.DefinitionSyncTest do
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Jobs.DefinitionSync

  describe "perform/1" do
    test "skips sync when feature flag is disabled" do
      original = Application.get_env(:mydia, :features, [])

      try do
        # Disable feature flag
        Application.put_env(:mydia, :features, cardigann_enabled: false)

        # Job should complete successfully without syncing
        assert :ok = perform_job(DefinitionSync, %{})
      after
        Application.put_env(:mydia, :features, original)
      end
    end

    @tag :external
    test "runs sync when feature flag is enabled" do
      original = Application.get_env(:mydia, :features, [])

      try do
        # Enable feature flag
        Application.put_env(:mydia, :features, cardigann_enabled: true)

        # Job should attempt to sync (limit to 1 file for speed)
        # This is marked as :external because it hits GitHub API
        assert :ok = perform_job(DefinitionSync, %{"limit" => 1})
      after
        Application.put_env(:mydia, :features, original)
      end
    end

    @tag :external
    test "handles sync with limit parameter" do
      original = Application.get_env(:mydia, :features, [])

      try do
        # Enable feature flag
        Application.put_env(:mydia, :features, cardigann_enabled: true)

        # Job should accept limit parameter
        assert :ok = perform_job(DefinitionSync, %{"limit" => 5})
      after
        Application.put_env(:mydia, :features, original)
      end
    end
  end
end
