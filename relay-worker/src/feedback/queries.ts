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
  await env.DB.prepare(
    "UPDATE feedback_submissions SET github_ref = ?, updated_at = ? WHERE id = ?",
  )
    .bind(ref, Math.floor(Date.now() / 1000), id)
    .run();
}
