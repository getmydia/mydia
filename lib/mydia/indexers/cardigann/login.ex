defmodule Mydia.Indexers.Cardigann.Login do
  @moduledoc """
  Authenticates against a Cardigann definition.

  The strategy comes from `login.method`, never from which credentials happen to be
  filled in. `begin/2` either returns a session or, for a form login with an image
  captcha or a one-time 2FA code, a `Challenge` that `complete/2` finishes once a
  person has answered it.
  """

  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.Cardigann.Login.{Challenge, Form, Inputs, Session, Simple}
  alias Mydia.Indexers.CardigannDefinition
  alias Mydia.Indexers.CardigannDefinition.Parsed

  @spec begin(Parsed.t(), CardigannDefinition.t()) ::
          {:ok, Session.t()} | {:needs_input, Challenge.t()} | {:error, Error.t()}
  def begin(%Parsed{login: nil}, _definition), do: {:ok, %Session{}}

  def begin(%Parsed{login: %{method: method}} = parsed, %CardigannDefinition{} = definition) do
    with {:ok, base} <- Inputs.base_url(parsed, definition) do
      args = %{
        parsed: parsed,
        definition: definition,
        config: definition.config || %{},
        base: base
      }

      case method do
        "cookie" -> Simple.run(:cookie, args)
        "get" -> Simple.run(:get, args)
        "post" -> Simple.run(:post, args)
        "form" -> Form.begin(args)
        other -> {:error, Error.invalid_config("Login method #{inspect(other)} is not supported")}
      end
    end
  end

  @doc "True when logging in to `parsed` needs a person (an image captcha or a 2FA code)."
  @spec needs_person?(Parsed.t()) :: boolean()
  def needs_person?(%Parsed{login: login}), do: Form.needs_person?(login)

  @spec complete(Challenge.t(), %{String.t() => String.t()}) ::
          {:ok, Session.t()} | {:error, Error.t()}
  def complete(%Challenge{} = challenge, answers), do: Form.complete(challenge, answers)
end
