import type { Env } from "./env";
import { HttpError } from "./http";
import { newId, now } from "./util";

/**
 * "About you": short sections the user writes. The user's text is authoritative. Facts the
 * assistant learns in conversation become suggestions that change nothing until accepted.
 */
export const PROFILE_SECTIONS = [
  { id: "first_name", title: "First name", question: "Their first name.", kind: "line" },
  { id: "last_name", title: "Last name", question: "Their last name.", kind: "line" },
  { id: "nickname", title: "Preferred name", question: "What they'd like Orbit to call them.", kind: "line" },
  { id: "timezone", title: "Time zone", question: "Where they usually are.", kind: "choice" },
  { id: "school", title: "School", question: "Where they study.", kind: "line" },
  { id: "major", title: "Major or program", question: "What they study.", kind: "line" },
  { id: "year", title: "Year", question: "Year in school.", kind: "choice" },
  { id: "work", title: "Work", question: "Student, part-time or full-time.", kind: "choice" },
  { id: "goals", title: "Goals & interests", question: "What are you working toward, and what do you enjoy?", kind: "text" },
  { id: "context", title: "Anything else", question: "Anything else Orbit should keep in mind.", kind: "text" },
] as const;
/** Single-value fields (typed, picked or a time), as opposed to free-form notes. */
const isLine = (id: string) => PROFILE_SECTIONS.some((s) => s.id === id && s.kind !== "text");
export type SectionId = (typeof PROFILE_SECTIONS)[number]["id"];
const SECTION_IDS = PROFILE_SECTIONS.map((s) => s.id) as readonly string[];
export const isSection = (v: unknown): v is SectionId => typeof v === "string" && SECTION_IDS.includes(v);

export const SECTION_MAX = 4000;
const MAX_PENDING = 25;

export interface ProfileSectionRow {
  id: SectionId;
  content: string;
  updated_at: number;
  updated_by: string | null;
}
export interface ProfileSuggestionRow {
  id: string;
  section: SectionId;
  content: string;
  source: string;
  source_ref: string | null;
  status: "pending" | "accepted" | "dismissed";
  created_at: number;
  updated_at: number;
}

export const normalize = (s: string) => s.toLowerCase().replace(/[“”"'’.!]+/g, "").replace(/\s+/g, " ").trim();
/** True when the profile text already says this (ignoring case, punctuation and spacing). */
export const alreadyCovered = (profile: string, fact: string) => {
  const n = normalize(fact);
  return !!n && normalize(profile).includes(n);
};
/** Appends a fact on its own line, unless it's already there. */
export const appendLine = (profile: string, fact: string) => {
  const line = fact.trim();
  if (!line || alreadyCovered(profile, line)) return profile;
  const base = profile.replace(/\s+$/, "");
  return base ? `${base}\n${line}` : line;
};

export async function getProfile(env: Env) {
  const [sections, suggestions] = await env.DB.batch([
    env.DB.prepare("SELECT id, content, updated_at, updated_by FROM profile_sections"),
    env.DB.prepare("SELECT id, section, content, source, source_ref, status, created_at, updated_at FROM profile_suggestions WHERE status = 'pending' ORDER BY created_at"),
  ]);
  const byId = new Map((sections.results as ProfileSectionRow[]).map((s) => [s.id, s]));
  return {
    sections: PROFILE_SECTIONS.map((s) => byId.get(s.id) ?? { id: s.id, content: "", updated_at: 0, updated_by: null }),
    suggestions: suggestions.results as ProfileSuggestionRow[],
  };
}

/**
 * The user's own edit. With `baseUpdatedAt`, refuses to overwrite a newer edit made on another device.
 * Pending suggestions the new text already covers are resolved, so they don't linger.
 */
export async function setSection(env: Env, id: string, content: string, deviceId: string | null, baseUpdatedAt?: number) {
  if (!isSection(id)) throw new HttpError(404, "Unknown section", "not_found");
  if (content.length > SECTION_MAX) throw new HttpError(400, "That section is too long", "validation");
  const text = content.replace(/\r\n/g, "\n").trim();
  const t = now();
  const r = await env.DB.prepare(
    `UPDATE profile_sections SET content = ?, updated_at = ?, updated_by = ? WHERE id = ? ${baseUpdatedAt != null ? "AND updated_at <= ?" : ""}`,
  )
    .bind(text, t, deviceId, id, ...(baseUpdatedAt != null ? [baseUpdatedAt] : []))
    .run();
  if (!r.meta.changes) {
    const cur = await env.DB.prepare("SELECT id, content, updated_at, updated_by FROM profile_sections WHERE id = ?").bind(id).first<ProfileSectionRow>();
    if (!cur) {
      await env.DB.prepare("INSERT INTO profile_sections (id, content, updated_at, updated_by) VALUES (?, ?, ?, ?)").bind(id, text, t, deviceId).run();
    } else {
      throw new HttpError(409, "This section changed on another device. Review the latest version and try again.", "conflict");
    }
  }
  const pending = await env.DB.prepare("SELECT id, content FROM profile_suggestions WHERE status = 'pending' AND section = ?").bind(id).all<{ id: string; content: string }>();
  const covered = pending.results.filter((s) => alreadyCovered(text, s.content));
  if (covered.length) {
    await env.DB.batch(covered.map((s) => env.DB.prepare("UPDATE profile_suggestions SET status = 'accepted', updated_at = ? WHERE id = ?").bind(t, s.id)));
  }
  return { id, content: text, updated_at: t };
}

/**
 * Called by the assistant. Never edits the profile: queues one suggestion for review, skipping anything
 * the profile already says and anything the user already saw (accepted or dismissed).
 */
export async function suggestProfileFact(env: Env, section: string, content: string, sourceRef: string | null) {
  const target: SectionId = isSection(section) ? section : "context";
  const text = content.trim().slice(0, 500);
  const norm = normalize(text);
  if (!norm) throw new HttpError(400, "content is required", "validation");
  const [cur, seen, pending] = await env.DB.batch([
    env.DB.prepare("SELECT content FROM profile_sections WHERE id = ?").bind(target),
    env.DB.prepare("SELECT status FROM profile_suggestions WHERE norm = ? LIMIT 1").bind(norm),
    env.DB.prepare("SELECT COUNT(*) AS n FROM profile_suggestions WHERE status = 'pending'"),
  ]);
  const profile = (cur.results[0] as { content?: string } | undefined)?.content ?? "";
  if (alreadyCovered(profile, text)) return { status: "already_in_profile" as const };
  const prior = (seen.results[0] as { status?: string } | undefined)?.status;
  if (prior) return { status: prior === "pending" ? ("already_suggested" as const) : ("already_reviewed" as const) };
  if (((pending.results[0] as { n?: number } | undefined)?.n ?? 0) >= MAX_PENDING) return { status: "review_queue_full" as const };
  const id = newId("psug");
  const t = now();
  await env.DB.prepare(
    "INSERT INTO profile_suggestions (id, section, content, norm, source, source_ref, status, created_at, updated_at) VALUES (?, ?, ?, ?, 'conversation', ?, 'pending', ?, ?)",
  )
    .bind(id, target, text, norm, sourceRef, t, t)
    .run();
  return { status: "suggested" as const, id, section: target };
}

/** The user accepts a suggestion (optionally reworded, optionally into another section). */
export async function acceptSuggestion(env: Env, id: string, deviceId: string | null, opts: { content?: string; section?: string } = {}) {
  const s = await env.DB.prepare("SELECT * FROM profile_suggestions WHERE id = ?").bind(id).first<ProfileSuggestionRow>();
  if (!s) throw new HttpError(404, "Suggestion not found", "not_found");
  if (s.status !== "pending") return { ok: true, status: s.status };
  const section: SectionId = opts.section && isSection(opts.section) ? opts.section : s.section;
  const fact = (opts.content ?? s.content).trim();
  const cur = await env.DB.prepare("SELECT content FROM profile_sections WHERE id = ?").bind(section).first<{ content: string }>();
  // Short fields (name, school…) hold one value: accepting replaces it. Longer ones gain a line.
  const next = isLine(section) ? fact : appendLine(cur?.content ?? "", fact);
  if (next.length > SECTION_MAX) throw new HttpError(400, "That section is full. Edit it to make room first.", "validation");
  const t = now();
  const stmts = [env.DB.prepare("UPDATE profile_suggestions SET status = 'accepted', section = ?, content = ?, updated_at = ? WHERE id = ? AND status = 'pending'").bind(section, fact, t, id)];
  if (next !== (cur?.content ?? "")) {
    stmts.push(env.DB.prepare("UPDATE profile_sections SET content = ?, updated_at = ?, updated_by = ? WHERE id = ?").bind(next, t, deviceId, section));
  }
  await env.DB.batch(stmts);
  return { ok: true, status: "accepted" };
}

export async function dismissSuggestion(env: Env, id: string) {
  const r = await env.DB.prepare("UPDATE profile_suggestions SET status = 'dismissed', updated_at = ? WHERE id = ? AND status = 'pending'").bind(now(), id).run();
  if (!r.meta.changes) {
    const exists = await env.DB.prepare("SELECT 1 FROM profile_suggestions WHERE id = ?").bind(id).first();
    if (!exists) throw new HttpError(404, "Suggestion not found", "not_found");
  }
  return { ok: true };
}

/** Profile text for the assistant's instructions. Empty sections are omitted. */
export function profileForPrompt(sections: { id: string; content: string }[]): string {
  return PROFILE_SECTIONS.map((s) => {
    const text = sections.find((x) => x.id === s.id)?.content.trim();
    if (!text) return "";
    if (s.kind !== "text" && !text.includes("\n")) return `${s.title}: ${text}`;
    return `${s.title}:\n${text.split("\n").map((l) => `  ${l}`).join("\n")}`;
  })
    .filter(Boolean)
    .join("\n");
}
