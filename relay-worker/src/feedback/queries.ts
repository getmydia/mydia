import type { Env } from "../env";
import type { FeedbackRow } from "./ingest";

export interface ListFeedbackOptions {
  state?: string;
  limit: number;
  offset: number;
}

export async function listFeedback(
  env: Env,
  opts: ListFeedbackOptions,
): Promise<FeedbackRow[]> {
  // Mirrors MetadataRelay.Feedback.list_submissions/1's maybe_filter/3: nil
  // and the literal "all" both mean "no filter", not a value to match
  // against the state column.
  const state = opts.state && opts.state !== "all" ? opts.state : undefined;

  const stmt = state
    ? env.DB.prepare(
        `SELECT * FROM feedback_submissions WHERE state = ?
         ORDER BY inserted_at DESC LIMIT ? OFFSET ?`,
      ).bind(state, opts.limit, opts.offset)
    : env.DB.prepare(
        `SELECT * FROM feedback_submissions
         ORDER BY inserted_at DESC LIMIT ? OFFSET ?`,
      ).bind(opts.limit, opts.offset);

  const { results } = await stmt.all<FeedbackRow>();
  return results;
}

export async function setFeedbackState(
  env: Env,
  id: string,
  state: "unread" | "read" | "archived",
): Promise<void> {
  await env.DB.prepare(
    "UPDATE feedback_submissions SET state = ?, updated_at = ? WHERE id = ?",
  )
    .bind(state, Math.floor(Date.now() / 1000), id)
    .run();
}

export async function setGithubRef(env: Env, id: string, ref: string): Promise<void> {
  // Mirrors Submission.github_ref_changeset/2: Ecto.Changeset.cast/4's
  // default `empty_values` (which includes "") normalizes a blank change
  // away entirely, so the Elixir side never persists "" -- a blank
  // submission leaves the struct's `nil` default in place. Trim first so a
  // whitespace-only submission is treated the same way (the Elixir cast
  // only special-cases the exact string "", but nothing here should ever
  // want to persist "   " as if it were a real reference either). A
  // non-blank ref is stored exactly as submitted, uninspected -- same as
  // the Elixir side, which never trims real content.
  const normalized = ref.trim() === "" ? null : ref;

  await env.DB.prepare(
    "UPDATE feedback_submissions SET github_ref = ?, updated_at = ? WHERE id = ?",
  )
    .bind(normalized, Math.floor(Date.now() / 1000), id)
    .run();
}
