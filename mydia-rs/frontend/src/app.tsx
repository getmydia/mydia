export function App() {
  return (
    <div className="min-h-screen bg-base-200 text-base-content">
      <div className="flex flex-col items-center justify-center min-h-screen gap-6 p-8">
        <h1 className="text-3xl font-bold">Mydia Admin</h1>

        <div className="card bg-base-100 shadow-xl w-full max-w-md">
          <div className="card-body">
            <h2 className="card-title">Welcome</h2>
            <p>The mydia-rs admin web UI is under construction.</p>
            <div className="card-actions justify-end">
              <button className="btn btn-primary">Get Started</button>
            </div>
          </div>
        </div>

        <div className="flex gap-2">
          <span className="badge badge-primary">primary</span>
          <span className="badge badge-secondary">secondary</span>
          <span className="badge badge-accent">accent</span>
          <span className="badge badge-success">success</span>
          <span className="badge badge-warning">warning</span>
          <span className="badge badge-error">error</span>
          <span className="badge badge-info">info</span>
        </div>

        <div className="flex gap-2 items-center">
          <input
            type="text"
            placeholder="Search..."
            className="input input-bordered w-48"
          />
          <button className="btn btn-outline btn-sm">Clear</button>
        </div>
      </div>
    </div>
  );
}
