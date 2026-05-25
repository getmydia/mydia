import { useState, useCallback } from "react";
import { useMutation } from "urql";
import { CreateMediaRequestDocument } from "../graphql/generated/graphql";
import { PageHeader } from "../components/page-header";
import { Card } from "../components/card";
import { Input } from "../components/input";
import { Button } from "../components/button";
import { Alert } from "../components/feedback";

export function RequestMediaPage() {
  const [{ fetching }, createRequest] = useMutation(CreateMediaRequestDocument);
  const [title, setTitle] = useState("");
  const [mediaType, setMediaType] = useState("movie");
  const [year, setYear] = useState("");
  const [tmdbId, setTmdbId] = useState("");
  const [notes, setNotes] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState(false);

  const handleSubmit = useCallback(
    async (e: React.FormEvent) => {
      e.preventDefault();
      setError(null);

      if (!title.trim()) {
        setError("Title is required.");
        return;
      }

      const res = await createRequest({
        input: {
          mediaType,
          title: title.trim(),
          originalTitle: null,
          year: year ? parseInt(year, 10) : null,
          tmdbId: tmdbId ? parseInt(tmdbId, 10) : null,
          imdbId: null,
          requesterNotes: notes.trim() || null,
        },
      });

      if (res.error) {
        setError(res.error.message);
      } else {
        setSuccess(true);
      }
    },
    [title, mediaType, year, tmdbId, notes, createRequest],
  );

  if (success) {
    return (
      <div>
        <PageHeader title="Request Media" />
        <Card>
          <div className="text-center space-y-4 py-8">
            <div className="text-4xl">&#10003;</div>
            <h2 className="text-xl font-semibold">Request Submitted</h2>
            <p className="text-base-content/60">
              Your request for <strong>{title}</strong> has been submitted.
            </p>
            <div className="flex justify-center gap-2">
              <a href="/my-requests" className="btn btn-primary">
                View My Requests
              </a>
              <Button
                variant="outline"
                onClick={() => {
                  setSuccess(false);
                  setTitle("");
                  setYear("");
                  setTmdbId("");
                  setNotes("");
                }}
              >
                Make Another
              </Button>
            </div>
          </div>
        </Card>
      </div>
    );
  }

  return (
    <div>
      <PageHeader title="Request Media" subtitle="Request a movie or TV show to be added" />

      {error && <Alert kind="error">{error}</Alert>}

      <Card className="max-w-lg">
        <form onSubmit={handleSubmit} className="space-y-4">
          <div className="form-control">
            <label className="label py-1">
              <span className="label-text">Media Type</span>
            </label>
            <select
              value={mediaType}
              onChange={(e) => setMediaType(e.target.value)}
              className="select select-bordered w-full"
            >
              <option value="movie">Movie</option>
              <option value="tv_show">TV Show</option>
            </select>
          </div>

          <Input
            label="Title"
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            placeholder="Enter title..."
            required
          />

          <Input
            label="Year (optional)"
            value={year}
            onChange={(e) => setYear(e.target.value)}
            placeholder="e.g. 2024"
            type="number"
          />

          <Input
            label="TMDB ID (optional)"
            value={tmdbId}
            onChange={(e) => setTmdbId(e.target.value)}
            placeholder="e.g. 12345"
            type="number"
          />

          <div className="form-control">
            <label className="label py-1">
              <span className="label-text">Notes (optional)</span>
            </label>
            <textarea
              value={notes}
              onChange={(e) => setNotes(e.target.value)}
              className="textarea textarea-bordered w-full"
              rows={3}
              placeholder="Any additional details..."
            />
          </div>

          <div className="pt-2">
            <Button type="submit" loading={fetching} className="w-full">
              Submit Request
            </Button>
          </div>
        </form>
      </Card>
    </div>
  );
}
