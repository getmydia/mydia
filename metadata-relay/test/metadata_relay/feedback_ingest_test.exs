defmodule MetadataRelay.FeedbackIngestTest do
  use ExUnit.Case, async: false

  alias MetadataRelay.Feedback
  alias MetadataRelay.Feedback.Submission
  alias MetadataRelay.Repo
  alias MetadataRelay.Router

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Repo.delete_all(Submission)
    Application.put_env(:swoosh, :shared_test_process, self())
    flush_mailbox()

    case GenServer.whereis(MetadataRelay.RateLimiter) do
      nil -> start_supervised!(MetadataRelay.RateLimiter)
      _pid -> :ok
    end

    :ets.delete_all_objects(:rate_limiter)

    on_exit(fn ->
      Application.delete_env(:swoosh, :shared_test_process)
    end)

    :ok
  end

  describe "POST /feedback" do
    test "stores valid feedback" do
      conn =
        post_feedback(%{
          "type" => "bug",
          "message" => "Playback froze",
          "contact" => "user@example.com",
          "instance_id" => "instance-1",
          "mydia_version" => "1.2.3"
        })

      assert conn.status == 201
      assert %{"status" => "created", "id" => id} = Jason.decode!(conn.resp_body)

      submission = Feedback.get_submission!(id)
      assert submission.type == "bug"
      assert submission.message == "Playback froze"
      assert submission.contact == "user@example.com"
      assert submission.instance_id == "instance-1"
      assert submission.mydia_version == "1.2.3"
      assert submission.source_ip == "127.0.0.1"

      email = await_email(fn email -> email.subject == "[Mydia feedback] bug: Playback froze" end)
      assert email.to == [{"", "maintainer@example.com"}]
      assert email.from == {"", "metadata-relay@example.com"}
    end

    test "includes submission details in the notification email" do
      conn =
        post_feedback(%{
          "type" => "idea",
          "message" => "Add watch party mode",
          "contact" => "user@example.com",
          "instance_id" => "instance-1",
          "mydia_version" => "1.2.3"
        })

      assert conn.status == 201

      email =
        await_email(fn email ->
          email.subject == "[Mydia feedback] idea: Add watch party mode"
        end)

      assert email.text_body =~ "Type: idea"
      assert email.text_body =~ "Contact: user@example.com"
      assert email.text_body =~ "Instance: instance-1"
      assert email.text_body =~ "Mydia version: 1.2.3"
      assert email.text_body =~ "Message:\nAdd watch party mode"
      assert email.text_body =~ "Dashboard: https://relay.example.com/feedback#feedback-"
    end

    test "sets reply-to to the contact when it is an email address" do
      conn =
        post_feedback(%{
          "type" => "bug",
          "message" => "Subtitles are offset",
          "contact" => "  Reporter@Example.COM  "
        })

      assert conn.status == 201

      email =
        await_email(fn email ->
          email.subject == "[Mydia feedback] bug: Subtitles are offset"
        end)

      assert email.reply_to == {"", "Reporter@Example.COM"}
      assert email.from == {"", "metadata-relay@example.com"}
    end

    test "omits reply-to when the contact is not an email address" do
      conn =
        post_feedback(%{
          "type" => "idea",
          "message" => "Add a dark theme",
          "contact" => "@some-github-handle"
        })

      assert conn.status == 201

      email =
        await_email(fn email -> email.subject == "[Mydia feedback] idea: Add a dark theme" end)

      assert email.reply_to == nil
    end

    test "omits reply-to when no contact was given" do
      conn = post_feedback(%{"type" => "question", "message" => "Where are logs stored?"})

      assert conn.status == 201

      email =
        await_email(fn email ->
          email.subject == "[Mydia feedback] question: Where are logs stored?"
        end)

      assert email.reply_to == nil
    end

    test "returns 400 when type is missing" do
      conn = post_feedback(%{"message" => "Playback froze"})

      assert conn.status == 400
      assert %{"error" => "Validation failed", "errors" => errors} = Jason.decode!(conn.resp_body)
      assert "Missing required field: type" in errors
    end

    test "returns 400 when message is missing" do
      conn = post_feedback(%{"type" => "bug"})

      assert conn.status == 400
      assert %{"error" => "Validation failed", "errors" => errors} = Jason.decode!(conn.resp_body)
      assert "Missing required field: message" in errors
    end

    test "returns 400 when type is invalid" do
      conn = post_feedback(%{"type" => "spam", "message" => "Buy now"})

      assert conn.status == 400
      assert %{"error" => "Validation failed", "errors" => errors} = Jason.decode!(conn.resp_body)
      assert "Invalid type: spam" in errors
    end

    test "returns 400 when an optional field has the wrong type" do
      conn =
        post_feedback(%{"type" => "bug", "message" => "Playback froze", "contact" => %{"x" => 1}})

      assert conn.status == 400
      assert %{"error" => "Validation failed", "errors" => errors} = Jason.decode!(conn.resp_body)
      assert "Invalid field: contact" in errors
    end

    test "returns 400 with a distinct body when message is too long" do
      conn = post_feedback(%{"type" => "bug", "message" => String.duplicate("a", 4097)})

      assert conn.status == 400

      assert %{"error" => "Message too long", "limit_bytes" => 4096} =
               Jason.decode!(conn.resp_body)
    end

    test "accepts omitted optional fields and ignores unknown fields" do
      conn =
        post_feedback(%{
          "type" => "question",
          "message" => "How does this work?",
          "extra_field" => "ignored"
        })

      assert conn.status == 201
      assert %{"id" => id} = Jason.decode!(conn.resp_body)

      submission = Feedback.get_submission!(id)
      assert submission.contact == nil
      assert submission.instance_id == nil
      assert submission.mydia_version == nil
    end

    # Regression guard for T-236: omitting `instance_id` used to fall back to
    # the literal shared string "anonymous", so every caller in the world who
    # left it out collided into one rate-limit bucket -- a caller with no
    # instance_id at all could send five feedback requests from five
    # different IPs and rate limit every *other* anonymous submitter for the
    # rest of the hour, since the trusted-forwarded-for IP check alone never
    # tripped for any of them individually. The fallback now scopes to the
    # caller's own (rate-limited) IP instead, so distinct callers omitting
    # instance_id no longer share a bucket.
    test "omitting instance_id does not create a shared bucket across different callers" do
      for i <- 1..5 do
        conn =
          post_feedback(%{"type" => "bug", "message" => "Message #{i}", "instance_id" => nil},
            forwarded_for: "203.0.113.#{i}"
          )

        assert conn.status == 201
      end

      # A sixth, distinct caller (its own IP, also no instance_id) must not
      # be blocked by the other five.
      conn =
        post_feedback(%{"type" => "bug", "message" => "Message 6", "instance_id" => nil},
          forwarded_for: "203.0.113.6"
        )

      assert conn.status == 201
      assert 6 == Repo.aggregate(Submission, :count, :id)
    end

    test "still rate limits the sixth request from one IP when instance_id is omitted" do
      for i <- 1..5 do
        conn =
          post_feedback(%{"type" => "bug", "message" => "Message #{i}", "instance_id" => nil})

        assert conn.status == 201
      end

      conn = post_feedback(%{"type" => "bug", "message" => "Message 6", "instance_id" => nil})

      assert conn.status == 429
      assert ["3600"] = Plug.Conn.get_resp_header(conn, "retry-after")
      assert 5 == Repo.aggregate(Submission, :count, :id)
    end

    test "rate limits the sixth request from one IP" do
      for i <- 1..5 do
        conn =
          post_feedback(%{
            "type" => "bug",
            "message" => "Message #{i}",
            "instance_id" => "instance-#{i}"
          })

        assert conn.status == 201
      end

      conn =
        post_feedback(%{
          "type" => "bug",
          "message" => "Message 6",
          "instance_id" => "instance-6"
        })

      assert conn.status == 429
      assert %{"error" => "Too many requests"} = Jason.decode!(conn.resp_body)
      assert ["3600"] = Plug.Conn.get_resp_header(conn, "retry-after")
      assert 5 == Repo.aggregate(Submission, :count, :id)
    end

    test "rate limits the sixth request for one instance from different IPs" do
      for i <- 1..5 do
        conn =
          post_feedback(%{"type" => "idea", "message" => "Message #{i}", "instance_id" => "same"},
            forwarded_for: "198.51.100.#{i}"
          )

        assert conn.status == 201
      end

      conn =
        post_feedback(%{"type" => "idea", "message" => "Message 6", "instance_id" => "same"},
          forwarded_for: "198.51.100.6"
        )

      assert conn.status == 429
      assert 5 == Repo.aggregate(Submission, :count, :id)
    end

    # Regression guard: the T-236 fallback introduced a new collision. The
    # fallback bucket for a caller who omits instance_id is keyed off
    # "ip:<client_ip>". A caller can *supply* instance_id: "ip:<victim_ip>"
    # and land in the exact same rate-limit bucket as the victim's fallback,
    # letting an attacker (spreading requests across throwaway IPs so their
    # own IP-keyed bucket never trips) exhaust the victim's fallback bucket
    # before the victim ever sends a request.
    test "a caller-supplied instance_id cannot collide with another caller's fallback bucket" do
      victim_ip = "203.0.113.77"

      for i <- 1..5 do
        conn =
          post_feedback(
            %{"type" => "bug", "message" => "Attacker #{i}", "instance_id" => "ip:#{victim_ip}"},
            forwarded_for: "198.51.100.#{i}"
          )

        assert conn.status == 201
      end

      # The victim, sending from their own IP with no instance_id at all,
      # must still get through -- their fallback bucket must not have been
      # exhausted by the attacker's crafted instance_id.
      conn =
        post_feedback(%{"type" => "bug", "message" => "Victim", "instance_id" => nil},
          forwarded_for: victim_ip
        )

      assert conn.status == 201
    end
  end

  defp post_feedback(body, opts \\ []) do
    conn =
      Plug.Test.conn(:post, "/feedback", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    conn =
      case Keyword.get(opts, :forwarded_for) do
        nil -> conn
        ip -> Plug.Conn.put_req_header(conn, "x-forwarded-for", ip)
      end

    conn
    |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
    |> Router.call([])
  end

  defp await_email(match?, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_email(match?, deadline)
  end

  defp do_await_email(match?, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:email, email} ->
        if match?.(email) do
          email
        else
          do_await_email(match?, deadline)
        end

      _other ->
        do_await_email(match?, deadline)
    after
      remaining ->
        flunk("expected matching feedback notification email")
    end
  end

  defp flush_mailbox do
    receive do
      _message -> flush_mailbox()
    after
      0 -> :ok
    end
  end
end
