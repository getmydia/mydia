defmodule MydiaWeb.FeatureCaseMessageTest do
  # The message wait_for_liveview/2 raises on timeout, tested as a pure
  # function. Deliberately not tagged :feature: it needs no browser, so it runs
  # in the default suite where a regression is caught immediately rather than
  # only in the E2E job.
  use ExUnit.Case, async: true

  alias MydiaWeb.FeatureCase

  describe "liveview_failure_message/2" do
    test "names the unconnected case when a root LiveView is present" do
      message = FeatureCase.liveview_failure_message(true, 15_000)

      assert message =~ "socket never joined"
      assert message =~ "15000ms"
      # The top cause in this repo is a worktree with no asset build, so the
      # message has to name the fix rather than leaving it to be rediscovered.
      assert message =~ "mix assets.build"
      refute message =~ "no element matches"
    end

    test "names the absent case when no root LiveView rendered" do
      message = FeatureCase.liveview_failure_message(false, 15_000)

      assert message =~ "No root LiveView rendered"
      assert message =~ "15000ms"
      assert message =~ "redirect"
      refute message =~ "mix assets.build"
    end
  end

  describe "login_redirect_failure_message/1" do
    test "names the path the browser is stuck on and the budget" do
      message = FeatureCase.login_redirect_failure_message(5_000)

      assert message =~ "/auth/local/login"
      assert message =~ "5000ms"
      # The only way a real test reaches this message is credentials the form
      # rejected, so the message has to say that rather than leave it to be
      # rediscovered.
      assert message =~ "credentials"
      assert message =~ "session_controller_test.exs"
    end
  end
end
