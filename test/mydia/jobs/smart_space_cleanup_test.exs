defmodule Mydia.Jobs.SmartSpaceCleanupTest do
  use Mydia.DataCase

  alias Mydia.Jobs.SmartSpaceCleanup

  test "perform/1 returns :ok when nothing is enabled" do
    assert :ok = SmartSpaceCleanup.perform(%Oban.Job{args: %{}})
  end
end
