import { useState, useCallback } from "react";
import { useMutation } from "urql";
import { AddMediaToLibraryDocument } from "../graphql/generated/graphql";
import { PageHeader } from "../components/page-header";
import { Card } from "../components/card";
import { Input } from "../components/input";
import { Button } from "../components/button";
import { Alert } from "../components/feedback";

export function AddMediaPage() {
  const [{ fetching }, addMedia] = useMutation(AddMediaToLibraryDocument);
  const [title, setTitle] = useState("");
  const [mediaType, setMediaType] = useState("movie");
  const [tmdbId, setTmdbId] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);

  const handleSubmit = useCallback(
    async (e: React.FormEvent) => {
      e.preventDefault();
      setError(null);
      setSuccess(null);

      if (!title.trim()) {
        setError("Title is required.");
        return;
      }

      const res = await addMedia({
        input: {
          mediaType,
          title: title.trim(),
          tmdbId: tmdbId ? parseInt(tmdbId, 10) : null,
          tvdbId: null,
          qualityProfileId: null,
          monitored: true,
          monitoringPreset: null,
        },
      });

      if (res.error) {
        setError(res.error.message);
      } else {
        setSuccess(`"${title}" added to library.`);
        setTitle("");
        setTmdbId("");
      }
    },
    [title, mediaType, tmdbId, addMedia],
  );

  return (
    <div>
      <PageHeader title="Add Media" subtitle="Add a movie or TV show to your library" />

      {error && <Alert kind="error">{error}</Alert>}
      {success && <Alert kind="success">{success}</Alert>}

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
            label="TMDB ID (optional)"
            value={tmdbId}
            onChange={(e) => setTmdbId(e.target.value)}
            placeholder="e.g. 12345"
            type="number"
          />

          <div className="pt-2">
            <Button type="submit" loading={fetching} className="w-full">
              Add to Library
            </Button>
          </div>
        </form>
      </Card>
    </div>
  );
}
