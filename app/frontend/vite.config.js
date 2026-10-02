import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  server: {
    // In local development, forward /api calls to the backend on port 3000.
    // In AWS, the ALB does this routing instead.
    proxy: {
      '/api': 'http://localhost:3000',
    },
  },
  build: {
    sourcemap: false,
  },
});
