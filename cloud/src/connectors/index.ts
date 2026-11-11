import type { Env } from "../env";
import { getAccount, listAccounts, type AccountRow } from "../accounts";
import { gmail } from "./google";
import { icloudMail } from "./icloud";
import type { MailMessage, MailSummary, OutgoingMail } from "./mail";

export interface MailProvider {
  search(env: Env, acct: AccountRow, q: string, max?: number): Promise<MailSummary[]>;
  recent(env: Env, acct: AccountRow, max?: number): Promise<MailSummary[]>;
  read(env: Env, acct: AccountRow, id: string): Promise<MailMessage>;
  createDraft(env: Env, acct: AccountRow, m: OutgoingMail): Promise<{ draft_id: string }>;
  send?(env: Env, acct: AccountRow, m: OutgoingMail): Promise<{ message_id: string }>;
  sendDraft?(env: Env, acct: AccountRow, draftId: string): Promise<{ message_id: string }>;
}

export const MAIL_PROVIDERS: Record<string, MailProvider> = { google: gmail, icloud_mail: icloudMail };

export async function mailAccount(env: Env, accountId?: string | null): Promise<{ acct: AccountRow; mail: MailProvider }> {
  let acct: AccountRow | undefined;
  if (accountId) acct = await getAccount(env, accountId);
  else acct = (await listAccounts(env)).find((a) => MAIL_PROVIDERS[a.provider]);
  if (!acct) throw new Error("No email account is connected. Connect Gmail or iCloud Mail in Settings.");
  const mail = MAIL_PROVIDERS[acct.provider];
  if (!mail) throw new Error(`Account ${acct.id} is not an email account`);
  return { acct, mail };
}

export async function firstAccount(env: Env, provider: string, accountId?: string | null): Promise<AccountRow> {
  if (accountId) {
    const a = await getAccount(env, accountId);
    if (a.provider !== provider) throw new Error(`Account ${accountId} is not a ${provider} account`);
    return a;
  }
  const a = (await listAccounts(env, provider))[0];
  if (!a) throw new Error(`No ${provider} account is connected.`);
  return a;
}
