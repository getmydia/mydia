defmodule Mydia.CrashReporter.SenderTest do
  # Mutates the global :metadata_relay_url application env.
  use ExUnit.Case, async: false

  alias Mydia.CrashReporter.Sender

  setup do
    previous = Application.fetch_env(:mydia, :metadata_relay_url)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:mydia, :metadata_relay_url, value)
        :error -> Application.delete_env(:mydia, :metadata_relay_url)
      end
    end)
  end

  test "an empty relay URL is reported as not configured, without a request" do
    Application.put_env(:mydia, :metadata_relay_url, "")

    report = %{error_type: "RuntimeError", error_message: "boom", stacktrace: []}

    assert {:error, :metadata_relay_not_configured} = Sender.send_report(report)
  end
end
