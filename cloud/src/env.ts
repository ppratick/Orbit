export interface Env {
  DB: D1Database;
  // Non-secret configuration (wrangler.jsonc "vars")
  OPENAI_MODEL: string;
  OPENAI_BASE_URL: string;
  ORBIT_TIMEZONE: string;
  ORBIT_CALENDAR_NAME: string;
  // Secrets
  ADMIN_TOKEN?: string;
  ENCRYPTION_KEY?: string; // base64, 32 bytes
  OPENAI_API_KEY?: string;
  /**
   * Which credential the model client uses:
   *  - "chatgpt": only the linked ChatGPT account (OAuth access token); fails if unavailable.
   *  - "api_key": only OPENAI_API_KEY.
   *  - "chatgpt_then_api_key": ChatGPT first; on auth/quota failure retry with the API key (logged).
   */
  OPENAI_AUTH_MODE?: string;
  // ChatGPT sign-in (OAuth 2.0 + PKCE) for the user's own registered Orbit client. All values come from
  // that client's registration; nothing here is hard-coded because it is specific to the user's client.
  CHATGPT_OAUTH_CLIENT_ID?: string;
  CHATGPT_OAUTH_AUTHORIZE_URL?: string;
  CHATGPT_OAUTH_TOKEN_URL?: string;
  CHATGPT_OAUTH_SCOPES?: string;
  CHATGPT_OAUTH_REDIRECT_URI?: string; // must exactly match the client registration
  CHATGPT_OAUTH_EXTRA_PARAMS?: string; // optional JSON object of extra authorize-URL params
  CHATGPT_RESPONSES_BASE_URL?: string; // defaults to OPENAI_BASE_URL
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
