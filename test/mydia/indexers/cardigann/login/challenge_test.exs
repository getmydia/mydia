defmodule Mydia.Indexers.Cardigann.Login.ChallengeTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.Login.Challenge

  test "inspect hides the credentials and cookie jar held in pending" do
    challenge = %Challenge{
      definition_id: "def-1",
      fields: ["captcha"],
      image: "PNGBYTES",
      pending: %{password: "hunter2-secret", cookies: ["PHPSESSID=abc123"]}
    }

    out = inspect(challenge)
    refute out =~ "hunter2-secret"
    refute out =~ "abc123"
    refute out =~ "PNGBYTES"
    assert out =~ "def-1"
  end
end
