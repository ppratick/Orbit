import { beforeEach, describe, expect, it, vi } from "vitest";
import { boundedCheck, nextGoalCheck, normalizedGoal, explicitAppleReminders, inspectAccountChanges } from "../../src/proactive";
import { MAIL_PROVIDERS, searchAllMail } from "../../src/connectors";
import { emailPhase, heartbeat } from "../../src/heartbeat";
import { QueryBudget } from "../../src/budget";
import type { Env } from "../../src/env";
import type { AccountRow } from "../../src/accounts";

vi.mock("../../src/accounts", async (original) => ({...await original<any>(),listAccounts:vi.fn(),setSyncState:vi.fn(),markAccountError:vi.fn(),accountSecret:vi.fn()}));
vi.mock("../../src/profile", async (original) => ({...await original<any>(),getProfile:vi.fn(async()=>({sections:[]}))}));
vi.mock("../../src/agent/llmauth", async (original) => ({...await original<any>(),llmConfigured:vi.fn(async()=>true)}));
vi.mock("../../src/agent/llm", async (original) => ({...await original<any>(),respond:vi.fn()}));
import { listAccounts, setSyncState, accountSecret } from "../../src/accounts";
import { drive, gmail } from "../../src/connectors/google";
import { respond } from "../../src/agent/llm";

const acct=(id:string,provider="google")=>({id,provider,status:"active",label:id,identity:`${id}@example.com`,last_sync_at:null}) as AccountRow;
const message={id:"m1",thread_id:"thread",from:"Professor",to:"me",subject:"Exam 3 makeup",snippet:"Your makeup is Friday.",date:100,unread:true};
function database(backlog:unknown[]=[]) {
  const writes:{sql:string;args:unknown[]}[]=[];
  const db={prepare:(sql:string)=>{
    let args:unknown[]=[];
    const statement={bind:(...a:unknown[])=>{args=a;return statement;},all:async()=>({results:sql.includes("SELECT * FROM email_items")?backlog:[]}),
      first:async()=>null,run:async()=>{writes.push({sql,args});return {meta:{changes:1}};}};
    return statement;
  },batch:async(rows:any[])=>Promise.all(rows.map((r)=>r.run()))};
  return {env:{DB:db,ORBIT_TIMEZONE:"America/New_York",OPENAI_MODEL_BASIC:"luna"} as unknown as Env,writes};
}

beforeEach(()=>{vi.restoreAllMocks();vi.mocked(listAccounts).mockResolvedValue([acct("school")]);vi.mocked(respond).mockReset();});
describe("proactive cadence",()=>{
  it("checks urgent items in hours and distant items in days, with bounded AI-selected intervals",()=>{
    const at=1_000_000, hour=3600_000;
    expect(nextGoalCheck(at+hour,at)).toBe(at+2*hour);
    expect(nextGoalCheck(at+10*24*hour,at)).toBe(at+72*hour);
    expect(nextGoalCheck(null,at)).toBe(at+24*hour);
    expect(boundedCheck(at-1,null,at)).toBe(at+2*hour);
    expect(boundedCheck(at+999*hour,null,at)).toBe(at+72*hour);
    expect(normalizedGoal("Finish P3! ")).toBe(normalizedGoal("finish   p3"));
  });
});
describe("reminder destination",()=>{
  it("requires an explicit Apple Reminders destination and respects negation",()=>{
    expect(explicitAppleReminders("Remind me at 5")).toBe(false);
    expect(explicitAppleReminders("Add it to my Reminders app")).toBe(true);
    expect(explicitAppleReminders("Use Apple Reminders for this")).toBe(true);
    expect(explicitAppleReminders("Do not use Apple Reminders")).toBe(false);
  });
});
describe("mailbox coverage",()=>{
  it("searches personal and school accounts by default, preserving account provenance",async()=>{
    vi.mocked(listAccounts).mockResolvedValue([acct("personal"),acct("school")]);
    const search=vi.spyOn(MAIL_PROVIDERS.google,"search").mockImplementation(async(_env,account)=>account.id==="school"?[message]:[]);
    const result=await searchAllMail(database().env,"SpaceX");
    expect(search).toHaveBeenCalledTimes(2);
    expect(result.accounts_searched.map((a)=>a.account_id)).toEqual(["personal","school"]);
    expect(result.messages[0].account_id).toBe("school");
    expect(result.incomplete).toBe(false);
  });
  it("reports an account failure rather than treating it as no matching mail",async()=>{
    vi.mocked(listAccounts).mockResolvedValue([acct("personal"),acct("school")]);
    vi.spyOn(MAIL_PROVIDERS.google,"search").mockImplementation(async(_env,account)=>{if(account.id==="school")throw new Error("expired credential");return [];});
    const result=await searchAllMail(database().env,"makeup");
    expect(result.incomplete).toBe(true);
    expect(result.accounts_searched[1].error).toBe("expired credential");
  });
});
describe("email triage regression",()=>{
  it("includes JSON in input and does not mark failed classifications applied",async()=>{
    vi.spyOn(MAIL_PROVIDERS.google,"recent").mockResolvedValue([message]);
    vi.mocked(respond).mockImplementation(async(_env,request)=>{
      expect(JSON.stringify(request.input)).toMatch(/json/i);
      throw new Error("temporary model failure");
    });
    const {env,writes}=database();
    const result=await emailPhase(env,new QueryBudget());
    expect(result.errors.join(" ")).toContain("temporary model failure");
    const insert=writes.find((w)=>w.sql.includes("INSERT INTO email_items"));
    expect(insert?.args[8]).toBeNull();
    expect(writes.some((w)=>w.sql.startsWith("UPDATE email_items SET triage"))).toBe(false);
  });
  it("recovers previously fetched unclassified mail even with no new inbox results",async()=>{
    vi.spyOn(MAIL_PROVIDERS.google,"recent").mockResolvedValue([]);
    vi.mocked(respond).mockResolvedValue({text:JSON.stringify({items:[{id:"school:m1",category:"fyi",summary:"No action",important:false}]}),calls:[],reasoning:[],via:"chatgpt",model:"luna"});
    const {env,writes}=database([{account_id:"school",provider_msg_id:"m1",thread_id:"thread",from_addr:"Professor",subject:"Update",snippet:"FYI",received_at:100,triage:null}]);
    const result=await emailPhase(env,new QueryBudget());
    expect(result.new).toBe(1);
    expect(result.pending).toBe(0);
    const applied=writes.find((w)=>w.sql.startsWith("UPDATE email_items SET triage"));
    expect(JSON.parse(applied!.args[0] as string).applied).toBe(true);
  });
  it("records partial heartbeat status when fetching or classification fails",async()=>{
    vi.spyOn(MAIL_PROVIDERS.google,"recent").mockRejectedValue(new Error("mail failure"));
    const {env,writes}=database();
    await heartbeat(env,"email");
    const update=writes.find((w)=>w.sql.startsWith("UPDATE heartbeat_runs"));
    expect(update?.args[1]).toBe("partial");
  });
});

describe("account change detection",()=>{
  it("records a baseline without invoking AI or enqueueing historical files",async()=>{
    vi.spyOn(drive,"search").mockResolvedValue([{id:"file",name:"Research plan"}] as any);
    const {env,writes}=database();
    const result=await inspectAccountChanges(env);
    expect(result.changed).toBe(0);
    expect(vi.mocked(respond)).not.toHaveBeenCalled();
    expect(writes.some((w)=>w.sql.includes("INSERT INTO chat_inbox"))).toBe(false);
    expect(vi.mocked(setSyncState)).toHaveBeenCalledWith(env,"school",expect.objectContaining({discovery_hash:expect.any(String)}));
  });
  it("enqueues changed evidence once for the existing conversation queue",async()=>{
    vi.mocked(listAccounts).mockResolvedValue([{...acct("school"),sync_state:JSON.stringify({discovery_hash:"previous"})}]);
    vi.spyOn(drive,"search").mockResolvedValue([{id:"file",name:"Updated research plan"}] as any);
    const {env,writes}=database();
    const result=await inspectAccountChanges(env);
    expect(result.changed).toBe(1);
    expect(writes.some((w)=>w.sql.includes("ON CONFLICT(client_msg_id) DO NOTHING"))).toBe(true);
    expect(writes.some((w)=>w.sql.includes("INSERT INTO chat_inbox"))).toBe(true);
    expect(vi.mocked(respond)).not.toHaveBeenCalled();
  });
});

describe("email retrieval",()=>{
  it("loads credentials once per Gmail search rather than once for every metadata result",async()=>{
    vi.mocked(accountSecret).mockClear();
    vi.mocked(accountSecret).mockResolvedValue({access_token:"test-only",expires_at:Date.now()+3600000});
    vi.spyOn(globalThis,"fetch").mockImplementation(async(input)=>new Response(JSON.stringify(String(input).includes("format=metadata")
      ? {id:"message",threadId:"thread",internalDate:"100",payload:{headers:[]}}
      : {messages:[{id:"a"},{id:"b"},{id:"c"}]}),{status:200}));
    expect(await gmail.search(database().env,acct("school"),"course")).toHaveLength(3);
    expect(vi.mocked(accountSecret)).toHaveBeenCalledTimes(1);
  });
  it("explains empty AND searches instead of encouraging more over-constrained synonyms",async()=>{
    vi.spyOn(MAIL_PROVIDERS.google,"search").mockResolvedValue([]);
    const result=await searchAllMail(database().env,"course exam retake retaking makeup");
    expect(result.search_hint).toMatch(/ALL words/);
    expect(result.search_hint).toMatch(/OR/);
  });
  it("loads Gmail conversation replies in chronological order including the latest arrangement",async()=>{
    vi.mocked(accountSecret).mockResolvedValue({access_token:"test-only",expires_at:Date.now()+3600000});
    const part=(text:string)=>({mimeType:"text/plain",headers:[],body:{data:btoa(text)}});
    const request=vi.spyOn(globalThis,"fetch").mockResolvedValue(new Response(JSON.stringify({messages:[
      {id:"latest",threadId:"t",internalDate:"200",payload:part("Tuesday is not confirmed yet.")},
      {id:"older",threadId:"t",internalDate:"100",payload:part("I can offer Tuesday.")},
    ]}),{status:200}));
    const thread=await gmail.readThread(database().env,acct("school"),"t");
    expect(String(request.mock.calls[0][0])).toContain("threads/t?format=full");
    expect(thread.map((m)=>m.id)).toEqual(["older","latest"]);
    expect(thread[1].body).toContain("not confirmed");
  });
});
