import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: { include: ["test/unit/**/*.test.ts"], environment: "node" },
  // fileURLToPath (not URL.pathname) so paths containing spaces resolve correctly.
  resolve: { alias: { "cloudflare:sockets": fileURLToPath(new URL("./test/unit/sockets-stub.ts", import.meta.url)) } },
});
