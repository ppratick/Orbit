-- Serialise ChatGPT token refreshes: refresh tokens rotate, so two concurrent refreshes would
-- invalidate each other. A short lease on the account row ensures one refresher at a time.
ALTER TABLE accounts ADD COLUMN lock_until INTEGER;
