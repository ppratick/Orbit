-- PKCE support for OAuth providers that require it (ChatGPT sign-in).
ALTER TABLE oauth_states ADD COLUMN code_verifier TEXT;
ALTER TABLE oauth_states ADD COLUMN redirect_uri TEXT;
