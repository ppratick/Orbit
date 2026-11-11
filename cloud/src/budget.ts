import type { Env } from "./env";

/**
 * Counts D1 statements so long-running jobs (heartbeat) stop cleanly before hitting
 * Workers Free's 50-queries-per-invocation limit. Batches are counted per statement (conservative).
 */
export class QueryBudget {
  used = 0;
  constructor(public limit = 44) {}
  left() {
    return this.limit - this.used;
  }
  ok(n = 1) {
    return this.used + n <= this.limit;
  }
  wrap(env: Env): Env {
    const self = this;
    const db = env.DB;
    const wrapStmt = (s: D1PreparedStatement): D1PreparedStatement =>
      new Proxy(s, {
        get(target, prop) {
          const v = Reflect.get(target, prop);
          if (prop === "bind") return (...a: unknown[]) => wrapStmt((v as (...x: unknown[]) => D1PreparedStatement).apply(target, a));
          if (prop === "run" || prop === "all" || prop === "first" || prop === "raw")
            return (...a: unknown[]) => {
              self.used++;
              return (v as (...x: unknown[]) => unknown).apply(target, a);
            };
          return typeof v === "function" ? v.bind(target) : v;
        },
      });
    const proxyDb = new Proxy(db, {
      get(target, prop) {
        const v = Reflect.get(target, prop);
        if (prop === "prepare") return (q: string) => wrapStmt(target.prepare(q));
        if (prop === "batch")
          return (stmts: D1PreparedStatement[]) => {
            self.used += stmts.length;
            return target.batch(stmts);
          };
        return typeof v === "function" ? v.bind(target) : v;
      },
    });
    return { ...env, DB: proxyDb };
  }
}
