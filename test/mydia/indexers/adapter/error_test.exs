defmodule Mydia.Indexers.Adapter.ErrorTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Adapter.Error

  describe "new/3" do
    test "creates error with type and message" do
      error = Error.new(:connection_failed, "Connection refused")

      assert %Error{
               type: :connection_failed,
               message: "Connection refused",
               details: nil
             } = error
    end

    test "creates error with details" do
      details = %{status: 400, body: "Bad request"}
      error = Error.new(:api_error, "Request failed", details)

      assert %Error{
               type: :api_error,
               message: "Request failed",
               details: ^details
             } = error
    end
  end

  describe "retry_after_ms/1" do
    test "reads delta-seconds, case-insensitively" do
      assert Error.retry_after_ms([{"Retry-After", "120"}]) == 120_000
      assert Error.retry_after_ms([{"retry-after", "7"}]) == 7_000
    end

    test "reads Req's map of lists and the host's name/value maps" do
      assert Error.retry_after_ms(%{"retry-after" => ["30"]}) == 30_000
      assert Error.retry_after_ms([%{name: "retry-after", value: "15"}]) == 15_000
    end

    test "reads an HTTP date in the future" do
      date =
        :calendar.universal_time()
        |> :calendar.datetime_to_gregorian_seconds()
        |> Kernel.+(90)
        |> :calendar.gregorian_seconds_to_datetime()
        |> http_date()

      assert ms = Error.retry_after_ms([{"Retry-After", date}])
      assert ms in 85_000..90_000
    end

    test "returns nil for past dates, negatives, garbage and no header" do
      assert Error.retry_after_ms([{"Retry-After", "Wed, 21 Oct 2015 07:28:00 GMT"}]) == nil
      assert Error.retry_after_ms([{"Retry-After", "-5"}]) == nil
      assert Error.retry_after_ms([{"Retry-After", "soon"}]) == nil
      assert Error.retry_after_ms([]) == nil
    end

    test "returns nil for values too short for the HTTP-date parser" do
      for value <- ["", "   ", "x", "abc"] do
        assert Error.retry_after_ms([{"Retry-After", value}]) == nil
      end
    end

    defp http_date({{y, m, d}, {hh, mm, ss}}) do
      day = Enum.at(~w(Mon Tue Wed Thu Fri Sat Sun), :calendar.day_of_the_week(y, m, d) - 1)
      mon = Enum.at(~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec), m - 1)
      pad = &String.pad_leading(Integer.to_string(&1), 2, "0")
      "#{day}, #{pad.(d)} #{mon} #{y} #{pad.(hh)}:#{pad.(mm)}:#{pad.(ss)} GMT"
    end
  end

  describe "error type helpers" do
    test "connection_failed/2 creates connection error" do
      error = Error.connection_failed("Connection refused")

      assert %Error{type: :connection_failed, message: "Connection refused"} = error
    end

    test "authentication_failed/2 creates auth error" do
      error = Error.authentication_failed("Invalid API key")

      assert %Error{type: :authentication_failed, message: "Invalid API key"} = error
    end

    test "timeout/2 creates timeout error" do
      error = Error.timeout("Request timed out")

      assert %Error{type: :timeout, message: "Request timed out"} = error
    end

    test "rate_limited/2 creates rate limited error" do
      error = Error.rate_limited("Too many requests", %{retry_after: 60})

      assert %Error{
               type: :rate_limited,
               message: "Too many requests",
               details: %{retry_after: 60}
             } = error
    end

    test "search_failed/2 creates search error" do
      error = Error.search_failed("No results found")

      assert %Error{type: :search_failed, message: "No results found"} = error
    end

    test "parse_error/2 creates parse error" do
      error = Error.parse_error("Invalid XML")

      assert %Error{type: :parse_error, message: "Invalid XML"} = error
    end

    test "invalid_config/2 creates config error" do
      error = Error.invalid_config("Missing API key")

      assert %Error{type: :invalid_config, message: "Missing API key"} = error
    end

    test "api_error/2 creates API error" do
      error = Error.api_error("Bad request", %{status: 400})

      assert %Error{
               type: :api_error,
               message: "Bad request",
               details: %{status: 400}
             } = error
    end

    test "network_error/2 creates network error" do
      error = Error.network_error("DNS failed")

      assert %Error{type: :network_error, message: "DNS failed"} = error
    end

    test "not_found/2 creates not found error" do
      error = Error.not_found("Indexer not found")

      assert %Error{type: :not_found, message: "Indexer not found"} = error
    end

    test "unknown/2 creates unknown error" do
      error = Error.unknown("Unexpected error")

      assert %Error{type: :unknown, message: "Unexpected error"} = error
    end
  end

  describe "from_req_error/1" do
    test "converts connection refused transport error" do
      req_error = %Req.TransportError{reason: :econnrefused}
      error = Error.from_req_error(req_error)

      assert %Error{
               type: :connection_failed,
               message: "Connection refused"
             } = error
    end

    test "converts timeout transport error" do
      req_error = %Req.TransportError{reason: :timeout}
      error = Error.from_req_error(req_error)

      assert %Error{
               type: :timeout,
               message: "Request timed out"
             } = error
    end

    test "converts DNS resolution error" do
      req_error = %Req.TransportError{reason: :nxdomain}
      error = Error.from_req_error(req_error)

      assert %Error{
               type: :network_error,
               message: "DNS resolution failed"
             } = error
    end

    test "converts generic transport error" do
      req_error = %Req.TransportError{reason: :some_other_reason}
      error = Error.from_req_error(req_error)

      assert %Error{
               type: :connection_failed,
               message: "Transport error: :some_other_reason"
             } = error
    end

    test "converts 401 response to authentication error" do
      response = %Req.Response{status: 401, body: "Unauthorized", headers: []}
      error = Error.from_req_error(response)

      assert %Error{
               type: :authentication_failed,
               message: "Authentication failed (401)",
               details: %{status: 401}
             } = error
    end

    test "converts 403 response to authentication error" do
      response = %Req.Response{status: 403, body: "Forbidden", headers: []}
      error = Error.from_req_error(response)

      assert %Error{
               type: :authentication_failed,
               message: "Access forbidden (403)",
               details: %{status: 403}
             } = error
    end

    test "converts 404 response to not found error" do
      response = %Req.Response{status: 404, body: "Not found", headers: []}
      error = Error.from_req_error(response)

      assert %Error{
               type: :not_found,
               message: "Resource not found (404)",
               details: %{status: 404}
             } = error
    end

    test "converts 429 response to rate limited error" do
      response = %Req.Response{status: 429, body: "Too many requests", headers: []}
      error = Error.from_req_error(response)

      assert %Error{
               type: :rate_limited,
               message: "Rate limit exceeded (429)",
               details: %{status: 429, retry_after: nil}
             } = error
    end

    test "converts 429 with retry-after header" do
      response = %Req.Response{
        status: 429,
        body: "Too many requests",
        headers: [{"retry-after", "120"}]
      }

      error = Error.from_req_error(response)

      assert %Error{
               type: :rate_limited,
               message: "Rate limit exceeded (429)",
               details: %{status: 429, retry_after: 120_000}
             } = error
    end

    test "converts 500 response to API error" do
      response = %Req.Response{status: 500, body: "Internal error", headers: []}
      error = Error.from_req_error(response)

      assert %Error{
               type: :api_error,
               message: "HTTP 500",
               details: %{status: 500, body: "Internal error"}
             } = error
    end

    test "converts unknown error types" do
      unknown_error = %{some: "error"}
      error = Error.from_req_error(unknown_error)

      assert %Error{
               type: :unknown,
               message: message
             } = error

      assert message =~ "Unexpected error"
    end
  end

  describe "message/1" do
    test "formats error message with type label" do
      error = Error.connection_failed("Connection refused")
      message = Error.message(error)

      assert message == "Connection failed: Connection refused"
    end

    test "formats multi-word error types" do
      error = Error.authentication_failed("Invalid credentials")
      message = Error.message(error)

      assert message == "Authentication failed: Invalid credentials"
    end

    test "formats error with underscores in type" do
      error = Error.invalid_config("Missing API key")
      message = Error.message(error)

      assert message == "Invalid config: Missing API key"
    end

    test "formats rate limited error" do
      error = Error.rate_limited("Too many requests")
      message = Error.message(error)

      assert message == "Rate limited: Too many requests"
    end
  end

  describe "exception/1" do
    test "creates exception from keyword list with all fields" do
      error =
        Error.exception(
          type: :connection_failed,
          message: "Connection refused",
          details: %{host: "localhost"}
        )

      assert %Error{
               type: :connection_failed,
               message: "Connection refused",
               details: %{host: "localhost"}
             } = error
    end

    test "creates exception with default values" do
      error = Error.exception(message: "Custom message")

      assert %Error{
               type: :unknown,
               message: "Custom message",
               details: nil
             } = error
    end

    test "creates exception from binary message" do
      error = Error.exception("Simple error message")

      assert %Error{
               type: :unknown,
               message: "Simple error message",
               details: nil
             } = error
    end
  end
end
