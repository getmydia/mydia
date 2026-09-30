defmodule MydiaWeb.PluginFrameToken do
  @moduledoc """
  Signed token that authenticates a plugin page's sandboxed iframe.

  The iframe runs in an opaque origin (no `allow-same-origin`), so it cannot
  use the session cookie. `MydiaWeb.PluginPageLive` mints this token for the
  signed-in user and passes it in the frame URL; the page's own requests send it
  back as `?frame_token=` or `x-mydia-frame-token`.

  Sessions here are stateless JWTs with no server-side record, so a token cannot
  be tied to a live session. It is instead a short-lived bearer: it expires
  after one hour and is bound to the user's current password hash, so a
  password change invalidates it at once. The controller also re-reads the user
  on every request, so a deleted user or a changed role takes effect
  immediately.
  """

  alias Mydia.Accounts.User

  @salt "plugin frame"
  @max_age 60 * 60

  @doc "The query parameter that carries the token."
  def param, do: "frame_token"

  @spec sign(String.t(), binary(), String.t()) :: String.t()
  def sign(slug, user_id, session_id) do
    Phoenix.Token.sign(MydiaWeb.Endpoint, @salt, %{
      slug: slug,
      user_id: user_id,
      session_id: session_id,
      credential: credential(Mydia.Accounts.get_user_by_id(user_id))
    })
  end

  @spec verify(String.t() | nil) ::
          {:ok,
           %{slug: String.t(), user_id: binary(), session_id: String.t(), credential: term()}}
          | {:error, atom()}
  def verify(token) when is_binary(token) and token != "" do
    Phoenix.Token.verify(MydiaWeb.Endpoint, @salt, token, max_age: @max_age)
  end

  def verify(_), do: {:error, :missing}

  @doc "True when the token's credential fingerprint still matches the user's."
  @spec current?(map(), User.t()) :: boolean()
  def current?(%{credential: credential}, %User{} = user), do: credential == credential(user)
  def current?(_claims, _user), do: false

  defp credential(%User{password_hash: hash}) do
    :crypto.hash(:sha256, hash || "") |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  defp credential(_), do: nil
end
