export interface Env {
  DB: D1Database;
  // Non-secret configuration (wrangler.jsonc "vars")
  /** Basic tasks (triage, titles, simple chat): GPT-6 Luna. */
  OPENAI_MODEL_BASIC: string;
  /** Harder tasks (multi-step tool work, drafting, research, planning): GPT-6.1 Sol. */
  OPENAI_MODEL_ADVANCED: string;
  OPENAI_BASE_URL: string;
  ORBIT_TIMEZONE: string;
  ORBIT_CALENDAR_NAME: string;
  // Secrets
  ADMIN_TOKEN?: string;
  ENCRYPTION_KEY?: string; // base64, 32 bytes
  /** Sign in with ChatGPT issuer. Defaults to https://auth.openai.com (overridable only for local tests). */
  SIWC_ISSUER?: string;
  /** Responses/models base URL for ChatGPT plan usage. Defaults to https://api.openai.com/v1. */
  CHATGPT_RESPONSES_BASE_URL?: string;
  GOOGLE_CLIENT_ID?: string;
  GOOGLE_CLIENT_SECRET?: string;
  PUBLIC_BASE_URL?: string;
  APNS_KEY_P8?: string;
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  APNS_TOPIC?: string;
  CF_ACCOUNT_ID?: string;
  CF_BROWSER_TOKEN?: string;
  NTFY_TOPIC_URL?: string; // optional fallback push channel
}
