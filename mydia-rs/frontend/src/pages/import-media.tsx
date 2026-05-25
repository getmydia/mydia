import { PageHeader } from "../components/page-header";
import { Card } from "../components/card";
import { Button } from "../components/button";

export function ImportMediaPage() {
  return (
    <div>
      <PageHeader
        title="Import Media"
        subtitle="Import media from external sources"
      />

      <Card title="Import Sessions">
        <p className="text-base-content/60 mb-4">
          Import functionality is being migrated. Check back soon for the full
          import workflow.
        </p>
        <Button disabled>New Import Session</Button>
      </Card>
    </div>
  );
}
