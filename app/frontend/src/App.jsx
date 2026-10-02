import { useEffect, useState } from 'react';

export default function App() {
  const [info, setInfo] = useState(null);
  const [error, setError] = useState(null);

  useEffect(() => {
    // Same-origin call: the ALB routes /api/* to the backend service,
    // so the frontend needs no backend URL and no CORS configuration.
    fetch('/api/info')
      .then((res) => {
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        return res.json();
      })
      .then(setInfo)
      .catch((err) => setError(err.message));
  }, []);

  return (
    <main className="container">
      <h1>ECS Fargate CI/CD Lab</h1>
      <p className="subtitle">React frontend + Node.js API on AWS ECS Fargate</p>

      {error && <p className="error">Backend unreachable: {error}</p>}
      {!info && !error && <p>Loading…</p>}

      {info && (
        <dl className="card">
          <dt>Environment</dt>
          <dd>{info.environment}</dd>
          <dt>Backend version</dt>
          <dd><code>{info.version}</code></dd>
          <dt>Message (from Parameter Store)</dt>
          <dd>{info.message}</dd>
          <dt>Secret loaded (from Secrets Manager)</dt>
          <dd>{info.secretConfigured ? 'Yes' : 'No'}</dd>
        </dl>
      )}
    </main>
  );
}
