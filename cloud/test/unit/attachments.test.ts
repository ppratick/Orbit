import {describe,it,expect} from "vitest";
import {attachmentType,attachmentMetadata,attachmentInputs} from "../../src/attachments";
import {buildBody} from "../../src/agent/llm";
import {toB64,fromB64} from "../../src/util";
import type {Env} from "../../src/env";

describe("attachments",()=>{
  it("checks real image/PDF signatures and rejects unsupported executable files",()=>{
    expect(attachmentType("screenshot.PNG",new Uint8Array([137,80,78,71,13,10,26,10]))).toBe("image/png");
    expect(attachmentType("notes.pdf",new TextEncoder().encode("%PDF-1.4"))).toBe("application/pdf");
    expect(()=>attachmentType("fake.png",new TextEncoder().encode("hello"))).toThrow(/contents/);
    expect(()=>attachmentType("script.exe",new Uint8Array([77,90]))).toThrow(/supported/);
  });
  it("rejects invalid attachment lists before querying the database",async()=>{
    const env={} as Env;
    await expect(attachmentMetadata(env,"c","att_invalid")).rejects.toMatchObject({status:400});
    await expect(attachmentMetadata(env,"c",Array(7).fill("att_a"))).rejects.toMatchObject({status:400});
    await expect(attachmentMetadata(env,"c",[5])).rejects.toMatchObject({status:400});
  });
  it("preserves multipart input without using unsupported file-upload APIs",()=>{
    const input=[{role:"user" as const,content:[{type:"input_text" as const,text:"Read this"},{type:"input_image" as const,image_url:"data:image/png;base64,eA=="},{type:"input_file" as const,filename:"notes.pdf",file_data:"data:application/pdf;base64,eA=="}]}];
    expect(buildBody({model:"gpt-6.1-sol",instructions:"test",input}).input).toEqual(input);
  });
  it("background work retains file references without resending an unrelated user's attachment",async()=>{
    const inputs=await attachmentInputs({} as Env,[
      {id:"photo",role:"user",content:"See photo",meta:JSON.stringify({attachments:[{id:"att_photo",name:"Photo.jpg"}]})},
      {id:"background",role:"system",content:"Check upcoming work"},
    ],"background");
    expect(inputs.get("photo")?.every(p=>p.type==="input_text")).toBe(true);
    expect(JSON.stringify(inputs.get("photo"))).toContain("read_attachment");
  });
  it("base64 encoding preserves binary data across large chunk boundaries",()=>{
    const bytes=Uint8Array.from({length:100000},(_,i)=>i%256);
    expect(fromB64(toB64(bytes))).toEqual(bytes);
  });
});
