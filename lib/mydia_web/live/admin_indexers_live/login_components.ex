defmodule MydiaWeb.AdminIndexersLive.LoginComponents do
  @moduledoc "The Log in button and captcha/2FA modal for Cardigann indexers."
  use MydiaWeb, :html

  attr :indexer, :map, required: true

  def login_button(assigns) do
    ~H"""
    <.row_action
      id={"indexer-login-#{@indexer.id}"}
      icon="hero-key"
      title="Log in"
      phx-click="indexer_login"
      phx-value-id={@indexer.id}
    />
    """
  end

  attr :challenge, :any, required: true
  attr :definition, :any, required: true
  attr :error, :string, default: nil
  attr :busy, :boolean, default: false

  def login_modal(assigns) do
    ~H"""
    <.modal id="indexer-login-modal" show on_cancel={JS.push("indexer_login_close")}>
      <:title>Log in to {@definition.name}</:title>
      <div :if={@error} class="alert alert-error mb-3 text-sm">{@error}</div>
      <.form
        for={%{}}
        as={:login}
        id="indexer-login-form"
        phx-submit="indexer_login_submit"
        class="space-y-4"
      >
        <div :if={"captcha" in @challenge.fields} class="space-y-2">
          <img
            :if={@challenge.image}
            id="indexer-login-captcha"
            src={"data:#{@challenge.image_type};base64,#{Base.encode64(@challenge.image)}"}
            alt="Captcha"
            class="rounded border border-base-300 bg-white"
          />
          <button
            id="indexer-login-refresh"
            type="button"
            class="btn btn-ghost btn-xs"
            phx-click="indexer_login_refresh"
            disabled={@busy}
          >
            <.icon name="hero-arrow-path" class="w-3 h-3" /> New image
          </button>
          <.input
            id="indexer-login-field-captcha"
            name="login[captcha]"
            value=""
            label="Text in the image"
            autocomplete="off"
          />
        </div>
        <.input
          :if={"2facode" in @challenge.fields}
          id="indexer-login-field-2facode"
          name="login[2facode]"
          value=""
          label="Two-factor code"
          inputmode="numeric"
          autocomplete="one-time-code"
        />
        <div class="modal-action">
          <button
            id="indexer-login-cancel"
            type="button"
            class="btn btn-ghost"
            phx-click="indexer_login_close"
          >
            Cancel
          </button>
          <button id="indexer-login-submit" type="submit" class="btn btn-primary" disabled={@busy}>
            <span :if={@busy} class="loading loading-spinner loading-sm"></span> Log in
          </button>
        </div>
      </.form>
    </.modal>
    """
  end
end
