import type { Hono } from "hono";
import type { Env } from "../env";

// router.ex's validate_feedback_type/2: only these three are accepted.
const TYPES = ["bug", "idea", "question"] as const;

// router.ex's `process_feedback/2` never reads a `state` from the request at
// all (get_feedback_param only reads type/message/contact/instance_id/
// mydia_version) -- every submission is created via Submission's schema
// default. A client-supplied `state` is silently ignored, not merely
// rejected, matching the producer exactly: it must not be a way to bypass
// triage by posting straight to "archived".
const DEFAULT_STATE = "unread";

export const MESSAGE_MAX_BYTES = 4096;

export interface Submission {
  id: string;
  type: string;
  message: string;
  contact: string | null;
  instance_id: string | null;
  mydia_version: string | null;
  source_ip: string | null;
  state: string;
  github_ref: string | null;
}

export interface FeedbackRow extends Submission {
  inserted_at: number;
  updated_at: number;
}

// Mirrors router.ex's require_feedback_field/3: is_binary(value) &&
// String.trim(value) != "" -- a value only counts as present when it is a
// string that isn't empty once whitespace is trimmed.
function isRequiredFieldPresent(value: unknown): value is string {
  return typeof value === "string" && value.trim() !== "";
}

// Mirrors router.ex's validate_feedback_type/2's own binary/non-empty guard,
// which runs independently of require_feedback_field/3 above (not gated on
// it) -- a whitespace-only type can produce BOTH "Missing required field:
// type" and "Invalid type: <raw value>" at once, same as router.ex.
function isNonEmptyBinary(value: unknown): value is string {
  return typeof value === "string" && value !== "";
}

// Mirrors router.ex's validate_optional_feedback_field/3: nil/absent is
// fine, any string (including "") is fine, anything else (a number, array,
// object, boolean) is rejected outright rather than silently coerced.
function isValidOptionalField(value: unknown): boolean {
  return value === undefined || value === null || typeof value === "string";
}

// Mirrors router.ex's normalize_optional_feedback_field/1: trims, then
// turns an empty result into nil. Unlike type/message, the stored value IS
// the trimmed string, not the raw one.
function normalizeOptional(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed === "" ? null : trimmed;
}

export function validateSubmission(
  body: Record<string, unknown>,
): { ok: true; value: Submission } | { ok: false; errors: string[] } {
  const errors: string[] = [];

  const type = body.type;
  const message = body.message;

  if (!isRequiredFieldPresent(type)) errors.push("Missing required field: type");
  if (!isRequiredFieldPresent(message)) errors.push("Missing required field: message");

  if (isNonEmptyBinary(type) && !TYPES.includes(type as (typeof TYPES)[number])) {
    errors.push(`Invalid type: ${type}`);
  }

  if (!isValidOptionalField(body.contact)) errors.push("Invalid field: contact");
  if (!isValidOptionalField(body.instance_id)) errors.push("Invalid field: instance_id");
  if (!isValidOptionalField(body.mydia_version)) errors.push("Invalid field: mydia_version");

  if (errors.length > 0) return { ok: false, errors };

  return {
    ok: true,
    value: {
      id: crypto.randomUUID(),
      // isRequiredFieldPresent narrowed these to `string` above; errors would
      // have been non-empty otherwise and we would have returned already.
      type: type as string,
      message: message as string,
      contact: normalizeOptional(body.contact),
      instance_id: normalizeOptional(body.instance_id),
      mydia_version: normalizeOptional(body.mydia_version),
      source_ip: null,
      state: DEFAULT_STATE,
      github_ref: null,
    },
  };
}

// Mirrors the guard in feedback/notifier.ex's @contact_address: strips CR
// and LF so a crafted contact or message excerpt cannot inject additional
// mail headers into the subject or reply-to fields sent to Resend's API.
export function sanitizeHeaderValue(value: string): string {
  return value.replace(/[\r\n]/g, " ").trim();
}

// Mirrors notifier.ex's @contact_address: `\A[^\s@,;:<>"]+@[^\s@,;:<>"]+\.[^\s@,;:<>"]+\z`.
// Deliberately whole-string anchored (JS's `^`/`$` without the `m` flag
// already behave like Elixir's `\A`/`\z`, unlike Elixir's own `^`/`$`, which
// are per-line anchors -- this is the exact case that comment warns about),
// so an embedded CR/LF can never sneak an extra "line" past the check.
const CONTACT_ADDRESS = /^[^\s@,;:<>"]+@[^\s@,;:<>"]+\.[^\s@,;:<>"]+$/;

function contactAsReplyTo(contact: string | null): string | null {
  if (contact === null) return null;
  return CONTACT_ADDRESS.test(contact) ? contact : null;
}

// notifier.ex's subject_preview/1: collapse all whitespace runs (not just
// CR/LF) to a single space, trim, then cap at 80 characters.
function subjectPreview(message: string): string {
  return message.replace(/\s+/g, " ").trim().slice(0, 80);
}

function optionalValue(value: string | null): string {
  return value ?? "-";
}

// Mirrors notifier.ex's deliver_new_submission/1 via Resend's HTTP API --
// Workers cannot open the SMTP connections Swoosh used. Called only after
// the row has already committed to D1 (see registerFeedbackRoutes below), so
// a Resend outage can never turn a stored submission into a client-visible
// error.
export async function notify(env: Env, submission: Submission): Promise<void> {
  if (!env.RESEND_API_KEY) return;

  const replyTo = contactAsReplyTo(submission.contact);

  const payload: Record<string, unknown> = {
    from: env.FEEDBACK_FROM,
    to: [env.FEEDBACK_TO],
    subject: sanitizeHeaderValue(
      `[Mydia feedback] ${submission.type}: ${subjectPreview(submission.message)}`,
    ),
    text: [
      "New Mydia feedback received.",
      "",
      `Type: ${submission.type}`,
      `Contact: ${optionalValue(submission.contact)}`,
      `Instance: ${optionalValue(submission.instance_id)}`,
      `Mydia version: ${optionalValue(submission.mydia_version)}`,
      `Source IP: ${optionalValue(submission.source_ip)}`,
      "",
      "Message:",
      submission.message,
    ].join("\n"),
  };

  if (replyTo) payload.reply_to = sanitizeHeaderValue(replyTo);

  await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      authorization: `Bearer ${env.RESEND_API_KEY}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });
}

export function registerFeedbackRoutes(app: Hono<{ Bindings: Env }>): void {
  // A method-specific route (app.post, not app.all) so the Task 14 dashboard
  // can later register app.get("/feedback", ...) without either route
  // swallowing the other -- Hono matches on path AND method.
  app.post("/feedback", async (c) => {
    const parsed: unknown = await c.req.json().catch(() => null);

    // router.ex's validate_feedback(_) catch-all: params must be a JSON
    // object (a map on the Elixir side), not an array, string, number, or
    // null.
    if (
      parsed === null ||
      typeof parsed !== "object" ||
      Array.isArray(parsed)
    ) {
      return c.json(
        { error: "Invalid JSON", message: "Request body must be valid JSON" },
        400,
      );
    }

    const body = parsed as Record<string, unknown>;
    const result = validateSubmission(body);
    if (!result.ok) {
      return c.json({ error: "Validation failed", errors: result.errors }, 400);
    }

    // Only checked once the other validations pass, matching router.ex's
    // `cond` ordering: errors != [] short-circuits before the byte-length
    // check ever runs. Uses the RAW (untrimmed) message, same as
    // byte_size(message) does on the Elixir side.
    const messageBytes = new TextEncoder().encode(result.value.message).length;
    if (messageBytes > MESSAGE_MAX_BYTES) {
      return c.json({ error: "Message too long", limit_bytes: MESSAGE_MAX_BYTES }, 400);
    }

    const now = Math.floor(Date.now() / 1000);
    const submission: Submission = {
      ...result.value,
      source_ip: c.req.header("cf-connecting-ip") ?? null,
    };

    await c.env.DB.prepare(
      `INSERT INTO feedback_submissions
         (id, type, message, contact, instance_id, mydia_version, source_ip,
          state, github_ref, inserted_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    )
      .bind(
        submission.id,
        submission.type,
        submission.message,
        submission.contact,
        submission.instance_id,
        submission.mydia_version,
        submission.source_ip,
        submission.state,
        submission.github_ref,
        now,
        now,
      )
      .run();

    // The row is already committed above. A Resend outage must never turn a
    // stored submission into a 500 that makes Mydia.Feedback.Sender retry
    // and duplicate it -- Sender only recognises 201 as success.
    c.executionCtx.waitUntil(notify(c.env, submission).catch(() => undefined));

    return c.json({ status: "created", id: submission.id }, 201);
  });
}
