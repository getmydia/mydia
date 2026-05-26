import { defineConfig } from "vite";
import react from "@vitejs/plugin-react-swc";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    allowedHosts: true,
    proxy: {
      "/graphql": {
        target: "http://127.0.0.1:4002",
        ws: false,
      },
      "/graphql/ws": {
        target: "ws://127.0.0.1:4002",
        ws: true,
      },
      "/api": {
        target: "http://127.0.0.1:4002",
      },
      "/api/graphql/socket": {
        target: "ws://127.0.0.1:4002",
        ws: true,
      },
      "/auth": {
        target: "http://127.0.0.1:4002",
      },
    },
  },
  build: {
    rollupOptions: {
      output: {
        assetFileNames: "assets/[name]-[hash][extname]",
        chunkFileNames: "assets/[name]-[hash].js",
        entryFileNames: "assets/[name]-[hash].js",
      },
    },
  },
});
