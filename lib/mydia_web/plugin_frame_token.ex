defmodule MydiaWeb.PluginFrameToken do
  @moduledoc """
  Signed token that authenticates a plugin page's sandboxed iframe.

  The iframe runs in an opaque origin (no `allow-same-origin`), so it cannot
  use the session cookie. `MydiaWeb.PluginPageLive` mints this token for the
  signed-in user and passes it in the frame URL; the page's own requests send it
  back as `?t=` or `x-mydia-frame-token`.
  """

  @salt "plugin frame"
  @max_age 12 * 60 * 60

  @spec sign(String.t(), binary(), String.t()) :: String.t()
  def sign(slug, user_id, session_id) do
    Phoenix.Token.sign(MydiaWeb.Endpoint, @salt, %{
      slug: slug,
      user_id: user_id,
      session_id: session_id
    })
  end

  @spec verify(String.t() | nil) ::
          {:ok, %{slug: String.t(), user_id: binary(), session_id: String.t()}}
          | {:error, atom()}
  def verify(token) when is_binary(token) and token != "" do
    Phoenix.Token.verify(MydiaWeb.Endpoint, @salt, token, max_age: @max_age)
  end

  def verify(_), do: {:error, :missing}
end
