import { createHash, randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import { z } from "zod";

export const EVIDENCE_BUCKET = "checklist-issue-evidence";
export const MAX_EVIDENCE_BYTES = 5 * 1024 * 1024;
export const EVIDENCE_SIGNED_URL_SECONDS = 60;
export const evidenceMimeSchema = z.enum(["image/jpeg", "image/png", "image/webp"]);
export type EvidenceMime = z.infer<typeof evidenceMimeSchema>;

export class EvidenceAccessError extends Error {}
export class EvidenceInputError extends Error {}
export class EvidenceConflictError extends Error {}
export class EvidenceUnavailableError extends Error {}

export type EvidenceMetadata = {
  id: string;
  status: "pending" | "draft" | "finalized";
  mime_type: EvidenceMime;
  byte_size: number;
};

export type EvidenceService = {
  upload(input:{actorUserId:string;branchId:string;checklistType:"kitchen_opening"|"foh_opening";itemId:string;bytes:Buffer;declaredMime:string;requestId:string}):Promise<EvidenceMetadata>;
  retire(actorUserId:string,evidenceId:string,requestId:string):Promise<void>;
  verifySet(actorUserId:string,branchId:string,checklistType:"kitchen_opening"|"foh_opening",evidenceIds:string[]):Promise<void>;
  createReadUrl(actorUserId:string,evidenceId:string):Promise<{evidence_id:string;signed_url:string;expires_in:number;mime_type:EvidenceMime}>;
};

const nonPersistentAuth={autoRefreshToken:false,detectSessionInUrl:false,persistSession:false} as const;
const uploadContextSchema=z.array(z.object({organization_id:z.uuid(),branch_id:z.uuid(),supervisor_user_id:z.uuid(),supervisor_team_id:z.uuid(),business_date:z.string()})).length(1);
const registrationSchema=z.array(z.object({id:z.uuid(),status:z.literal("pending"),mime_type:evidenceMimeSchema,byte_size:z.coerce.number().int().positive().max(MAX_EVIDENCE_BYTES),retired_object_paths:z.array(z.string()).max(10)})).length(1);
const storedEvidenceSchema=z.array(z.object({id:z.uuid(),item_id:z.string(),storage_object_path:z.string(),mime_type:evidenceMimeSchema,byte_size:z.coerce.number().int().positive().max(MAX_EVIDENCE_BYTES),sha256_checksum:z.string().regex(/^[0-9a-f]{64}$/),status:z.enum(["pending","draft","finalized"])})).max(18);
const readSchema=z.array(storedEvidenceSchema.element.omit({item_id:true})).length(1);
const retiredSchema=z.array(z.object({id:z.uuid(),storage_object_path:z.string()})).max(100);
type EvidenceClient={rpc:(name:string,args?:Record<string,unknown>)=>PromiseLike<{data:unknown;error:{code?:string}|null}>;storage:{from:(bucket:string)=>{upload:(path:string,bytes:Buffer,options:Record<string,unknown>)=>PromiseLike<{data:unknown;error:unknown}>;remove:(paths:string[])=>PromiseLike<{data:unknown;error:unknown}>;info:(path:string)=>PromiseLike<{data:{size?:number;contentType?:string;metadata?:unknown}|null;error:unknown}>;createSignedUrl:(path:string,seconds:number)=>PromiseLike<{data:{signedUrl?:string}|null;error:unknown}>}}};

export function inspectEvidenceImage(bytes:Buffer,declaredMime:string):{mime:EvidenceMime;extension:"jpg"|"png"|"webp";checksum:string}{
  if(bytes.length===0||bytes.length>MAX_EVIDENCE_BYTES)throw new EvidenceInputError();
  const mime=evidenceMimeSchema.safeParse(declaredMime.toLowerCase());
  if(!mime.success)throw new EvidenceInputError();
  const jpeg=bytes.length>=4&&bytes[0]===0xff&&bytes[1]===0xd8&&bytes[2]===0xff&&bytes.at(-2)===0xff&&bytes.at(-1)===0xd9;
  const pngSignature=Buffer.from([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]);
  const png=bytes.length>=33&&bytes.subarray(0,8).equals(pngSignature)&&bytes.subarray(12,16).toString("ascii")==="IHDR"&&bytes.subarray(bytes.length-8,bytes.length-4).toString("ascii")==="IEND";
  const webp=bytes.length>=20&&bytes.subarray(0,4).toString("ascii")==="RIFF"&&bytes.subarray(8,12).toString("ascii")==="WEBP"&&bytes.readUInt32LE(4)===bytes.length-8;
  const detected=jpeg?{mime:"image/jpeg" as const,extension:"jpg" as const}:png?{mime:"image/png" as const,extension:"png" as const}:webp?{mime:"image/webp" as const,extension:"webp" as const}:null;
  if(!detected||detected.mime!==mime.data)throw new EvidenceInputError();
  return{...detected,checksum:createHash("sha256").update(bytes).digest("hex")};
}

export function createEvidenceService(url:string,secretKey:string):EvidenceService{
  const client=createClient(url,secretKey,{auth:nonPersistentAuth});
  return createEvidenceServiceFromClient(client as unknown as EvidenceClient);
}

export function createEvidenceServiceFromClient(client:EvidenceClient):EvidenceService{
  const storage=client.storage.from(EVIDENCE_BUCKET);
  async function rpc(name:string,args:Record<string,unknown>){
    const result=await client.rpc(name,args);
    if(result.error){
      if(result.error.code==="23505")throw new EvidenceConflictError();
      if(result.error.code==="22023")throw new EvidenceInputError();
      if(result.error.code==="42501")throw new EvidenceAccessError();
      throw new EvidenceUnavailableError();
    }
    return result.data;
  }
  async function removeObjects(paths:string[],evidenceId:string,requestId:string,byteCount:number,stage:string){
    if(!paths.length)return;
    const result=await storage.remove(paths);
    if(result.error)console.warn("Evidence storage compensation",{requestId,evidenceId,byteCount,stage,category:"storage_cleanup_failed",status:503,compensation:"failed"});
  }
  async function cleanupExpired(requestId:string){
      let rows: z.infer<typeof retiredSchema> = [];
    try{rows=retiredSchema.parse(await rpc("retire_expired_phase4a_evidence",{max_rows:25}));}catch{return;}
    for(const row of rows)await removeObjects([row.storage_object_path],row.id,requestId,0,"pending_expiry_cleanup");
  }
  async function verifyStored(row:z.infer<typeof storedEvidenceSchema>[number]){
    const result=await storage.info(row.storage_object_path);
    if(result.error||!result.data)throw new EvidenceInputError();
    const metadata=(result.data.metadata??{}) as Record<string,unknown>;
    const storedSize=Number(result.data.size??metadata.size??metadata.contentLength);
    const checksum=String(metadata.sha256Checksum??metadata.sha256_checksum??"");
    const evidenceId=String(metadata.evidenceId??metadata.evidence_id??"");
    const mime=String(metadata.mimeType??metadata.mime_type??result.data.contentType??metadata.mimetype??"");
    if(storedSize!==row.byte_size||checksum!==row.sha256_checksum||evidenceId!==row.id||mime!==row.mime_type)throw new EvidenceInputError();
  }
  return{
    async upload(input){
      const inspected=inspectEvidenceImage(input.bytes,input.declaredMime);
      await cleanupExpired(input.requestId);
      const context=uploadContextSchema.parse(await rpc("authorize_phase4a_evidence_upload",{actor_user_id:input.actorUserId,target_branch_id:input.branchId,target_checklist_type:input.checklistType,target_item_id:input.itemId}))[0];
      const evidenceId=randomUUID();
      const objectPath=`${context.organization_id}/${context.branch_id}/${context.supervisor_team_id}/${context.business_date}/${evidenceId}.${inspected.extension}`;
      const upload=await storage.upload(objectPath,input.bytes,{contentType:inspected.mime,cacheControl:"0",upsert:false,metadata:{evidenceId,sha256Checksum:inspected.checksum,byteSize:String(input.bytes.length),mimeType:inspected.mime}});
      if(upload.error)throw new EvidenceUnavailableError();
      try{
        const registered=registrationSchema.parse(await rpc("register_phase4a_evidence_upload",{actor_user_id:input.actorUserId,target_branch_id:input.branchId,target_checklist_type:input.checklistType,target_item_id:input.itemId,evidence_id:evidenceId,object_path:objectPath,detected_mime_type:inspected.mime,actual_byte_size:input.bytes.length,checksum_sha256:inspected.checksum}))[0];
        await removeObjects(registered.retired_object_paths,evidenceId,input.requestId,input.bytes.length,"replace_cleanup");
        return{id:registered.id,status:registered.status,mime_type:registered.mime_type,byte_size:registered.byte_size};
      }catch(error){
        await removeObjects([objectPath],evidenceId,input.requestId,input.bytes.length,"registration_compensation");
        throw error;
      }
    },
    async retire(actorUserId,evidenceId,requestId){
      const rows=retiredSchema.parse(await rpc("retire_phase4a_evidence",{actor_user_id:actorUserId,target_evidence_id:evidenceId}));
      await removeObjects(rows.map(row=>row.storage_object_path),evidenceId,requestId,0,"retire_cleanup");
    },
    async verifySet(actorUserId,branchId,checklistType,evidenceIds){
      if(new Set(evidenceIds).size!==evidenceIds.length||evidenceIds.length>18)throw new EvidenceInputError();
      const rows=storedEvidenceSchema.parse(await rpc("authorize_phase4a_evidence_set",{actor_user_id:actorUserId,target_branch_id:branchId,target_checklist_type:checklistType,evidence_ids:evidenceIds}));
      if(rows.length!==evidenceIds.length)throw new EvidenceAccessError();
      await Promise.all(rows.map(verifyStored));
    },
    async createReadUrl(actorUserId,evidenceId){
      const row=readSchema.parse(await rpc("authorize_phase4a_evidence_read",{actor_user_id:actorUserId,target_evidence_id:evidenceId}))[0];
      await verifyStored({...row,item_id:"authorized"});
      const result=await storage.createSignedUrl(row.storage_object_path,EVIDENCE_SIGNED_URL_SECONDS);
      if(result.error||!result.data?.signedUrl)throw new EvidenceUnavailableError();
      return{evidence_id:row.id,signed_url:result.data.signedUrl,expires_in:EVIDENCE_SIGNED_URL_SECONDS,mime_type:row.mime_type};
    },
  };
}
