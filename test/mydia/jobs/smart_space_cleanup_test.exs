defmodule Mydia.Jobs.SmartSpaceCleanupTest do
  use Mydia.DataCase
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Jobs.SmartSpaceCleanup

  test "perform/1 returns :ok when nothing is enabled" do
    assert :ok = perform_job(SmartSpaceCleanup, %{})
  end
end
