const { createApp } = require('./app');

const port = Number(process.env.PORT) || 3000;

const server = createApp().listen(port, () => {
  console.log(JSON.stringify({ level: 'info', msg: 'backend listening', port }));
});

// ECS sends SIGTERM when it stops a task (deployments, scale-in).
// Finish in-flight requests, then exit before ECS sends SIGKILL.
function shutdown(signal) {
  console.log(JSON.stringify({ level: 'info', msg: 'shutting down', signal }));
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 10000).unref();
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
