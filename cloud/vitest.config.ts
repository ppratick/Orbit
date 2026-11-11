import { defineConfig } from "vitest/config";

export default defineConfig({
  test: { include: ["test/unit/**/*.test.ts"], environment: "node" },
  resolve: { alias: { "cloudflare:sockets": new URL("./test/unit/sockets-stub.ts", import.meta.url).pathname } },
});
