const express = require('express');

/**
 * Builds the Express app. Configuration is injected (defaults to process.env)
 * so tests can run without touching real environment variables.
 */
function createApp(config = process.env) {
  const app = express();
  app.disable('x-powered-by');
  app.use(express.json({ limit: '100kb' }));

  // Structured JSON access logs. Never log headers or bodies: they can carry
  // tokens or personal data.
  if (config.APP_ENV !== 'test') {
    app.use((req, res, next) => {
      const start = process.hrtime.bigint();
      res.on('finish', () => {
        const ms = Number(process.hrtime.bigint() - start) / 1e6;
        console.log(JSON.stringify({
          level: 'info',
          msg: 'request',
          method: req.method,
          path: req.path,
          status: res.statusCode,
          duration_ms: Math.round(ms),
        }));
      });
      next();
    });
  }

  // Used by the ALB target group and the ECS container health check.
  app.get('/api/health', (req, res) => {
    res.json({ status: 'ok' });
  });

  // Shows which version and configuration are live. Used by the pipeline's
  // smoke test. It reports *whether* the secret is set, never its value.
  app.get('/api/info', (req, res) => {
    res.json({
      service: 'backend',
      environment: config.APP_ENV || 'local',
      version: config.APP_VERSION || 'dev',
      message: config.APP_MESSAGE || 'Hello from the backend',
      secretConfigured: Boolean(config.API_SECRET),
    });
  });

  app.use((req, res) => {
    res.status(404).json({ error: 'not_found' });
  });

  return app;
}

module.exports = { createApp };
