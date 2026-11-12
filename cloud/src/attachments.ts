import type { Env } from "./env";
import { HttpError } from "./http";
import { fromB64, newId, now, parseJson, toB64 } from "./util";
import type { InputContent } from "./agent/llm";

export const MAX_ATTACHMENT = 5 * 1024 * 1024;
export const MAX_MESSAGE_BYTES = 10 * 1024 * 1024;
export const MAX_ATTACHMENTS = 6;
const STORAGE_LIMIT = 200 * 1024 * 1024;
const CHUNK_SIZE = 384 * 1024;
const TYPES: Record<string,string> = {
  jpg:"image/jpeg",jpeg:"image/jpeg",png:"image/png",gif:"image/gif",webp:"image/webp",
  pdf:"application/pdf",txt:"text/plain",md:"text/markdown",csv:"text/csv",tsv:"text/tab-separated-values",
  json:"application/json",html:"text/html",xml:"application/xml",log:"text/plain",
  doc:"application/msword",docx:"application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  xls:"application/vnd.ms-excel",xlsx:"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  ppt:"application/vnd.ms-powerpoint",pptx:"application/vnd.openxmlformats-officedocument.presentationml.presentation",rtf:"application/rtf",
  py:"text/x-python",js:"text/javascript",ts:"text/plain",swift:"text/plain",c:"text/plain",cpp:"text/plain",h:"text/plain",java:"text/plain",go:"text/plain",rs:"text/plain",sql:"text/plain",yaml:"text/plain",yml:"text/plain",
};
export interface Attachment { id:string; conversation_id:string; message_id:string|null; name:string; mime:string; size:number; sha256:string; created_at:number }
export const publicAttachment = (a:Attachment) => ({id:a.id,name:a.name,mime:a.mime,size:a.size});

export function attachmentType(name:string, data:Uint8Array):string {
  const ext=name.split(".").pop()?.toLowerCase() ?? "";
  const mime=TYPES[ext];
  if(!mime) throw new HttpError(400,"This file type isn't supported. Try a photo, PDF, document, spreadsheet or text file.","attachment_type");
  const starts=(bytes:number[])=>bytes.every((v,i)=>data[i]===v);
  const ascii=new TextDecoder().decode(data.slice(0,12));
  if ((mime==="image/jpeg"&&!starts([255,216,255])) || (mime==="image/png"&&!starts([137,80,78,71,13,10,26,10])) ||
      (mime==="image/gif"&&!ascii.startsWith("GIF8")) || (mime==="image/webp"&&!(ascii.startsWith("RIFF")&&ascii.slice(8)==="WEBP")) ||
      (mime==="application/pdf"&&!ascii.startsWith("%PDF-")) || (["docx","xlsx","pptx"].includes(ext)&&!ascii.startsWith("PK")))
    throw new HttpError(400,"The file contents don't match its extension. Export it again and retry.","attachment_type");
  return mime;
}

async function cryptoKey(env:Env) {
  if(!env.ENCRYPTION_KEY) throw new HttpError(503,"Attachment encryption isn't configured","configuration");
  return crypto.subtle.importKey("raw",fromB64(env.ENCRYPTION_KEY),"AES-GCM",false,["encrypt","decrypt"]);
}

export async function uploadAttachment(env:Env,conversationId:string,name:string,data:Uint8Array):Promise<Attachment> {
  if(!data.length || data.length>MAX_ATTACHMENT) throw new HttpError(413,"Files must be between 1 byte and 5 MB. Export a smaller copy and retry.","attachment_size");
  name=name.replace(/[\x00-\x1f\x7f/\\]/g,"_").trim().slice(0,180);
  if(!name) throw new HttpError(400,"A filename is required","validation");
  const mime=attachmentType(name,data);
  if(!await env.DB.prepare("SELECT 1 FROM conversations WHERE id=?").bind(conversationId).first()) throw new HttpError(404,"Conversation not found","not_found");
  // Discard abandoned uploads after a day, without touching sent attachments.
  await env.DB.prepare("DELETE FROM attachments WHERE message_id IS NULL AND created_at < ?").bind(now()-864e5).run();
  const usage=await env.DB.prepare("SELECT COALESCE(SUM(size),0) AS total FROM attachments").first<{total:number}>();
  if((usage?.total??0)+data.length>STORAGE_LIMIT) throw new HttpError(413,"Orbit's attachment storage is full. Larger storage needs to be enabled before adding more files.","attachment_storage");
  const iv=crypto.getRandomValues(new Uint8Array(12));
  const cipher=new Uint8Array(await crypto.subtle.encrypt({name:"AES-GCM",iv},await cryptoKey(env),data));
  const encrypted=new Uint8Array(iv.length+cipher.length); encrypted.set(iv); encrypted.set(cipher,12);
  const hash=Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256",data)),b=>b.toString(16).padStart(2,"0")).join("");
  const a:Attachment={id:newId("att"),conversation_id:conversationId,message_id:null,name,mime,size:data.length,sha256:hash,created_at:now()};
  await env.DB.batch([
    env.DB.prepare("INSERT INTO attachments (id,conversation_id,name,mime,size,sha256,created_at) VALUES (?,?,?,?,?,?,?)").bind(a.id,conversationId,name,mime,a.size,hash,a.created_at),
    ...Array.from({length:Math.ceil(encrypted.length/CHUNK_SIZE)},(_,position)=>env.DB.prepare("INSERT INTO attachment_chunks VALUES (?,?,?)").bind(a.id,position,encrypted.slice(position*CHUNK_SIZE,(position+1)*CHUNK_SIZE).buffer)),
  ]);
  return a;
}

export async function attachmentMetadata(env:Env,conversationId:string,ids:unknown):Promise<Attachment[]> {
  if(!Array.isArray(ids)||ids.length>MAX_ATTACHMENTS||ids.some(id=>typeof id!=="string")) throw new HttpError(400,"Attach up to six files per message","attachment_count");
  if(!ids.length) return [];
  const unique=[...new Set(ids as string[])];
  const rows=await env.DB.prepare(`SELECT * FROM attachments WHERE conversation_id=? AND id IN (${unique.map(()=>"?").join(",")})`).bind(conversationId,...unique).all<Attachment>();
  if(rows.results.length!==unique.length) throw new HttpError(404,"An attachment is missing. Please attach the file again.","attachment_missing");
  if(rows.results.reduce((s,a)=>s+a.size,0)>MAX_MESSAGE_BYTES) throw new HttpError(413,"Keep attachments under 10 MB combined per message","attachment_size");
  return unique.map(id=>rows.results.find(a=>a.id===id)!);
}

export async function attachmentBytes(env:Env,id:string):Promise<Uint8Array> {
  const chunks=await env.DB.prepare("SELECT data FROM attachment_chunks WHERE attachment_id=? ORDER BY position").bind(id).all<{data:number[]}>();
  if(!chunks.results.length) throw new HttpError(404,"Attachment not found","not_found");
  const parts=chunks.results.map(r=>new Uint8Array(r.data));
  const encrypted=new Uint8Array(parts.reduce((n,p)=>n+p.length,0)); let offset=0;
  for(const part of parts){encrypted.set(part,offset);offset+=part.length;}
  return new Uint8Array(await crypto.subtle.decrypt({name:"AES-GCM",iv:encrypted.slice(0,12)},await cryptoKey(env),encrypted.slice(12)));
}

export async function attachmentContent(env:Env,a:Attachment):Promise<InputContent> {
  const bytes=await attachmentBytes(env,a.id);
  // UTF-8 text needs no file parser and remains usable on the plan's file-upload-free route.
  if(a.mime.startsWith("text/")||["application/json","application/xml"].includes(a.mime)) {
    const text=new TextDecoder().decode(bytes);
    return {type:"input_text",text:`<untrusted-attachment name=${JSON.stringify(a.name)} id=${a.id}>\n${text.slice(0,80000)}${text.length>80000 ? "\n[Only the first 80,000 characters are included. This file is truncated; do not claim to have read the whole file.]" : ""}\n</untrusted-attachment>`};
  }
  const encoded=toB64(bytes);
  return a.mime.startsWith("image/") ? {type:"input_image",image_url:`data:${a.mime};base64,${encoded}`,detail:"auto"}
    : {type:"input_file",filename:a.name,file_data:`data:${a.mime};base64,${encoded}`};
}

export async function attachmentInputs(env:Env,rows:{id:string;role:string;content:string;meta?:string|null}[], eagerMessageId?:string):Promise<Map<string,InputContent[]>> {
  const result=new Map<string,InputContent[]>(); let bytes=0,count=0;
  const latest=eagerMessageId ?? [...rows].reverse().find(r=>r.role === "user")?.id;
  for(const row of [...rows].reverse()) {
    if(row.role!=="user") continue;
    const refs=parseJson<{attachments?:{id:string;name:string}[]}>(row.meta??null,{}).attachments;
    if(!refs?.length) continue;
    const parts:InputContent[]=[{type:"input_text",text:row.content||"Please review the attached files."}];
    if(row.id!==latest) {
      parts.push({type:"input_text",text:"Earlier attachments: "+refs.map(r=>`${r.name} (${r.id})`).join(", ")+". Use read_attachment to reopen the relevant file when needed."});
      result.set(row.id,parts); continue;
    }
    const metadata=await env.DB.prepare(`SELECT * FROM attachments WHERE id IN (${refs.map(()=>"?").join(",")})`).bind(...refs.map(r=>r.id)).all<Attachment>();
    for(const ref of refs) {
      const a=metadata.results.find(a=>a.id===ref.id);
      if(!a){parts.push({type:"input_text",text:`Attachment ${ref.name} is no longer available.`});continue;}
      if(bytes+a.size>12*1024*1024||count>=8){parts.push({type:"input_text",text:`Earlier attachment: ${a.name} (${a.id}). Use read_attachment to reopen it if needed.`});continue;}
      parts.push(await attachmentContent(env,a)); bytes+=a.size;count++;
    }
    result.set(row.id,parts);
  }
  return result;
}
