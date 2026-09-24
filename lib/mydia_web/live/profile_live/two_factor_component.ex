defmodule MydiaWeb.ProfileLive.TwoFactorComponent do
  @moduledoc """
  Profile card for enrolling in, managing and disabling TOTP two-factor
  authentication.

  A LiveComponent because enrollment is a multi-step flow with its own events,
  and the new secret must stay in this process, never persisted, until the user
  proves their authenticator has it. It takes `user_id` rather than the user so
  a parent re-render cannot overwrite freshly-enabled state with a stale struct.
  """
  use MydiaWeb, :live_component

  alias Mydia.Accounts

  @rate_limited_message "Too many login attempts. Please try again later."

  @impl true
  def update(%{user_id: user_id} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:step, fn -> :idle end)
     |> assign_new(:error, fn -> nil end)
     |> assign_new(:secret, fn -> nil end)
     |> assign_new(:qr_svg, fn -> nil end)
     |> assign_new(:recovery_codes, fn -> [] end)
     |> assign_new(:form, fn -> code_form() end)
     |> load_status(user_id)}
  end

  @impl true
  def handle_event("start_enroll", _params, socket) do
    %{secret: secret, uri: uri} = Accounts.begin_totp_enrollment(socket.assigns.user)
    qr_svg = uri |> EQRCode.encode() |> EQRCode.svg(width: 200)

    {:noreply,
     assign(socket,
       step: :enrolling,
       secret: secret,
       qr_svg: qr_svg,
       error: nil,
       form: code_form()
     )}
  end

  def handle_event("confirm_enroll", %{"totp" => %{"code" => code}}, socket) do
    case Accounts.confirm_totp_enrollment(socket.assigns.user, socket.assigns.secret, code) do
      {:ok, _user, codes} ->
        {:noreply,
         socket
         |> assign(step: :show_codes, recovery_codes: codes, secret: nil, qr_svg: nil, error: nil)
         |> load_status(socket.assigns.user_id)}

      {:error, :invalid_code} ->
        {:noreply,
         assign(socket,
           error:
             "That code didn't match. Check that your device's clock is correct and try again.",
           form: code_form()
         )}
    end
  end

  def handle_event("start_regenerate", _params, socket) do
    {:noreply, assign(socket, step: :regenerating, error: nil, form: code_form())}
  end

  def handle_event("regenerate", %{"totp" => %{"code" => code}}, socket) do
    user = socket.assigns.user

    case rate_limited(user, fn -> Accounts.regenerate_recovery_codes(user, code) end) do
      {:ok, codes} ->
        {:noreply,
         socket
         |> assign(step: :show_codes, recovery_codes: codes, error: nil)
         |> load_status(socket.assigns.user_id)}

      {:error, :rate_limited} ->
        {:noreply, assign(socket, error: @rate_limited_message)}

      {:error, :invalid_code} ->
        {:noreply, assign(socket, error: "Invalid code", form: code_form())}
    end
  end

  def handle_event("start_disable", _params, socket) do
    {:noreply,
     assign(socket,
       step: :disabling,
       error: nil,
       form: to_form(%{"password" => "", "code" => ""}, as: :disable_totp)
     )}
  end

  def handle_event(
        "disable",
        %{"disable_totp" => %{"password" => password, "code" => code}},
        socket
      ) do
    user = socket.assigns.user

    case rate_limited(user, fn -> Accounts.disable_totp(user, password, code) end) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> reset_flow()
         |> put_flash(:info, "Two-factor authentication turned off.")
         |> load_status(socket.assigns.user_id)}

      {:error, :rate_limited} ->
        {:noreply, assign(socket, error: @rate_limited_message)}

      {:error, :invalid_password} ->
        {:noreply, assign(socket, error: "Current password is incorrect")}

      {:error, :invalid_code} ->
        {:noreply, assign(socket, error: "Invalid code")}
    end
  end

  def handle_event("close", _params, socket) do
    {:noreply, reset_flow(socket)}
  end

  defp reset_flow(socket) do
    assign(socket, step: :idle, secret: nil, qr_svg: nil, recovery_codes: [], error: nil)
  end

  # Wraps an authenticated second-factor check with the same throttle as
  # login: an authenticated LiveView session could otherwise brute-force a
  # 6-digit code straight through `regenerate` or `disable` with no rate
  # limit. LiveView has no reliable client IP, so the account itself stands
  # in for it; the username bucket is the real username, so profile-page
  # failures spend the same per-account budget as password-login failures.
  defp rate_limited(user, fun) do
    ip_key = "profile:#{user.id}"
    username = user.username

    case Accounts.check_login_rate_limit(ip_key, username) do
      :ok ->
        case fun.() do
          {:ok, _} = ok ->
            Accounts.reset_login_rate_limit(ip_key, username)
            ok

          {:error, reason} = error when reason in [:invalid_code, :invalid_password] ->
            Accounts.record_login_failure(ip_key, username)
            error
        end

      {:error, :rate_limited} = error ->
        error
    end
  end

  defp load_status(socket, user_id) do
    user = Accounts.get_user!(user_id)

    assign(socket,
      user: user,
      enabled?: Accounts.totp_enabled?(user),
      remaining: Accounts.recovery_codes_remaining(user)
    )
  end

  defp code_form, do: to_form(%{"code" => ""}, as: :totp)

  defp secret_text(secret), do: Base.encode32(secret, padding: false)

  defp codes_download_href(codes) do
    "data:text/plain;charset=utf-8," <> URI.encode(Enum.join(codes, "\n") <> "\n")
  end

  defp recovery_codes_summary(1), do: "1 recovery code left"
  defp recovery_codes_summary(remaining), do: "#{remaining} recovery codes left"

  @impl true
  def render(assigns) do
    ~H"""
    <div id="two-factor-card" class="mt-6 border-t border-base-300 pt-6">
      <h3 class="font-semibold flex items-center gap-2 mb-2">
        <.icon name="hero-device-phone-mobile" class="w-5 h-5" /> Two-factor authentication
      </h3>

      <%= if @enabled? do %>
        <div id="totp-status" class="flex flex-wrap items-center gap-3 mb-4">
          <span class="badge badge-success">On</span>
          <span class="text-sm text-base-content/70">
            Enabled {Calendar.strftime(@user.totp_enabled_at, "%b %d, %Y")} · {recovery_codes_summary(
              @remaining
            )}
          </span>
        </div>
        <div class="flex flex-wrap gap-2">
          <button
            type="button"
            id="totp-regenerate-btn"
            class="btn btn-outline btn-sm"
            phx-click="start_regenerate"
            phx-target={@myself}
          >
            <.icon name="hero-arrow-path" class="w-4 h-4" /> New recovery codes
          </button>
          <button
            type="button"
            id="totp-disable-btn"
            class="btn btn-ghost btn-sm text-error"
            phx-click="start_disable"
            phx-target={@myself}
          >
            Turn off
          </button>
        </div>
      <% else %>
        <p class="text-base-content/70 mb-4">
          Ask for a code from an authenticator app each time you sign in with your password.
        </p>
        <button
          type="button"
          id="totp-enable-btn"
          class="btn btn-outline"
          phx-click="start_enroll"
          phx-target={@myself}
        >
          <.icon name="hero-shield-check" class="w-4 h-4" /> Set up two-factor authentication
        </button>
      <% end %>

      <div :if={@step != :idle} class="modal modal-open" id="totp-enroll-modal">
        <div class="modal-box">
          <button
            :if={@step != :show_codes}
            type="button"
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            phx-click="close"
            phx-target={@myself}
          >
            <.icon name="hero-x-mark" class="w-4 h-4" />
          </button>

          <div :if={@error} class="alert alert-error mb-4" id="totp-modal-error">
            <.icon name="hero-exclamation-circle" class="w-5 h-5" />
            <span>{@error}</span>
          </div>

          <%= case @step do %>
            <% :enrolling -> %>
              <h3 class="font-bold text-lg mb-2">Scan with your authenticator</h3>
              <p class="text-sm text-base-content/70 mb-4">
                Scan the code with an app such as Aegis, 2FAS or 1Password, or enter the key by hand.
              </p>
              <div id="totp-qr" class="flex justify-center bg-white rounded-box p-3 mb-3">
                {Phoenix.HTML.raw(@qr_svg)}
              </div>
              <code
                id="totp-secret"
                class="block font-mono text-sm break-all bg-base-200 rounded p-2 mb-4 select-all"
              >
                {secret_text(@secret)}
              </code>
              <.form
                for={@form}
                id="totp-confirm-form"
                phx-submit="confirm_enroll"
                phx-target={@myself}
              >
                <.input
                  field={@form[:code]}
                  type="text"
                  label="6-digit code"
                  autocomplete="one-time-code"
                  inputmode="numeric"
                  required
                />
                <div class="modal-action">
                  <button type="button" class="btn btn-ghost" phx-click="close" phx-target={@myself}>
                    Cancel
                  </button>
                  <button type="submit" class="btn btn-primary">Turn on</button>
                </div>
              </.form>
            <% :regenerating -> %>
              <h3 class="font-bold text-lg mb-4">New recovery codes</h3>
              <p class="text-sm text-base-content/70 mb-4">
                Your current recovery codes will stop working.
              </p>
              <.form
                for={@form}
                id="totp-regenerate-form"
                phx-submit="regenerate"
                phx-target={@myself}
              >
                <.input
                  field={@form[:code]}
                  type="text"
                  label="Authentication code"
                  autocomplete="one-time-code"
                  required
                />
                <div class="modal-action">
                  <button type="button" class="btn btn-ghost" phx-click="close" phx-target={@myself}>
                    Cancel
                  </button>
                  <button type="submit" class="btn btn-primary">Generate</button>
                </div>
              </.form>
            <% :disabling -> %>
              <h3 class="font-bold text-lg mb-4">Turn off two-factor authentication</h3>
              <.form for={@form} id="totp-disable-form" phx-submit="disable" phx-target={@myself}>
                <.input field={@form[:password]} type="password" label="Current password" required />
                <.input
                  field={@form[:code]}
                  type="text"
                  label="Authentication code or recovery code"
                  autocomplete="one-time-code"
                  required
                />
                <div class="modal-action">
                  <button type="button" class="btn btn-ghost" phx-click="close" phx-target={@myself}>
                    Cancel
                  </button>
                  <button type="submit" class="btn btn-error">Turn off</button>
                </div>
              </.form>
            <% :show_codes -> %>
              <h3 class="font-bold text-lg mb-2">Save your recovery codes</h3>
              <p class="text-sm text-base-content/70 mb-4">
                Each code signs you in once if you lose your authenticator. They won't be shown again.
              </p>
              <ul
                id="recovery-codes"
                class="grid grid-cols-2 gap-2 font-mono text-sm bg-base-200 rounded-box p-4 mb-4"
              >
                <li :for={code <- @recovery_codes}>{code}</li>
              </ul>
              <div class="modal-action">
                <a
                  id="recovery-codes-download"
                  class="btn btn-outline"
                  href={codes_download_href(@recovery_codes)}
                  download="mydia-recovery-codes.txt"
                >
                  <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> Download
                </a>
                <button
                  type="button"
                  id="totp-done-btn"
                  class="btn btn-primary"
                  phx-click="close"
                  phx-target={@myself}
                >
                  I saved these
                </button>
              </div>
          <% end %>
        </div>
        <div
          :if={@step != :show_codes}
          class="modal-backdrop bg-black/50"
          phx-click="close"
          phx-target={@myself}
        >
        </div>
      </div>
    </div>
    """
  end
end
