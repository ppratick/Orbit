import type { Env } from "./env";

/** Human-readable local time for tool results and chat messages, so replies never show UTC/epoch timestamps. */
export function localTime(env: Env, v: string | number | null | undefined): string | null {
  if (v === null || v === undefined || v === "") return null;
  const d = new Date(v);
  if (Number.isNaN(d.getTime())) return null;
  return new Intl.DateTimeFormat("en-US", { timeZone: env.ORBIT_TIMEZONE, weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }).format(d);
}
