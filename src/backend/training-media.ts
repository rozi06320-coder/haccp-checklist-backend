import { createHash, randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import sharp from "sharp";
import { z } from "zod";

export const TRAINING_MEDIA_BUCKET = "training-media";
export const MAX_TRAINING_MEDIA_SOURCE_BYTES = 5 * 1024 * 1024;
export const MAX_TRAINING_MEDIA_PIXELS = 40_000_000;
export const TRAINING_MEDIA_SIGNED_URL_SECONDS = 5 * 60;
export const TRAINING_MEDIA_MIN_LONG_EDGE = 1280;
export const TRAINING_MEDIA_MIN_SHORT_EDGE = 720;
const MAX_STORED_LONG_EDGE = 2560;
const locales = ["en", "ar", "id", "hi", "fil"] as const;

const uuid = z.uuid();
const i18n = z.object({ en:z.string().trim().min(1).max(500), ar:z.string().trim().min(1).max(500), id:z.string().trim().min(1).max(500), hi:z.string().trim().min(1).max(500), fil:z.string().trim().min(1).max(500) }).strict();
export const trainingMediaMetadataSchema = z.object({
  asset_key:z.string().trim().min(1).max(160).regex(/^[a-z0-9]+(?:[a-z0-9_-]*[a-z0-9])?$/),
  title_i18n:i18n,
  alt_i18n:i18n,
}).strict();

const mediaRow = z.object({
  id:uuid, asset_key:z.string(), media_type:z.literal("image"), title_i18n:i18n, alt_i18n:i18n,
  mime_type:z.literal("image/webp"), byte_size:z.number().int().positive(), width:z.number().int().positive(),
  height:z.number().int().positive(), approval_status:z.enum(["submitted","approved","rejected"]),
  status:z.enum(["ready","retired"]), created_at:z.string(), updated_at:z.string(),
}).passthrough();
export const trainingImageSlotRowSchema = z.object({
  module_id:uuid,module_key:z.string(),module_position:z.number().int().nonnegative(),module_title_i18n:i18n,
  lesson_id:uuid,lesson_key:z.string(),lesson_position:z.number().int().nonnegative(),lesson_title_i18n:i18n,
  asset_key:z.string(),placement:z.string(),purpose_i18n:i18n,expected_alt_i18n:i18n,
  media_id:uuid.nullable(),media_status:z.enum(["ready","retired"]).nullable(),approval_status:z.enum(["submitted","approved","rejected"]).nullable(),
  width:z.number().int().positive().nullable(),height:z.number().int().positive().nullable(),preview_available:z.boolean(),
}).strict();
const draftVersionRow = z.object({ course_id:uuid,course_key:z.string(),course_version_id:uuid,version_number:z.number().int().positive(),title_i18n:z.record(z.string(),z.unknown()),supported_locales:z.array(z.string()),status:z.literal("draft") }).strict();
const storageRow = z.object({storage_bucket:z.literal(TRAINING_MEDIA_BUCKET),storage_object_path:z.string(),mime_type:z.literal("image/webp")}).strict();

export class TrainingMediaAccessError extends Error {}
export class TrainingMediaInputError extends Error {}
export class TrainingMediaConflictError extends Error {}
export class TrainingMediaNotFoundError extends Error {}
export class TrainingMediaUnavailableError extends Error {}

export type TrainingMediaDto = z.infer<typeof mediaRow> & { preview_url:string };
export type TrainingImageSlotDto = z.infer<typeof trainingImageSlotRowSchema> & { preview_url:string|null };
type Scope={actorUserId:string;organizationId:string;courseId:string;courseVersionId:string;requestId:string};
export type TrainingMediaService = {
  listDraftVersions(actorUserId:string,organizationId:string):Promise<z.infer<typeof draftVersionRow>[]>;
  list(scope:Omit<Scope,"requestId">):Promise<TrainingMediaDto[]>;
  listSlots(scope:Omit<Scope,"requestId">):Promise<TrainingImageSlotDto[]>;
  create(scope:Scope,input:z.infer<typeof trainingMediaMetadataSchema>&{bytes:Buffer;declaredMime:string}):Promise<TrainingMediaDto>;
  replace(scope:Scope,input:z.infer<typeof trainingMediaMetadataSchema>&{assetId:string;bytes:Buffer;declaredMime:string}):Promise<TrainingMediaDto>;
  updateMetadata(scope:Omit<Scope,"requestId">,input:z.infer<typeof trainingMediaMetadataSchema>&{assetId:string}):Promise<TrainingMediaDto>;
  retire(scope:Scope,assetId:string):Promise<void>;
  authorizeAdminRead(scope:Omit<Scope,"requestId">,assetId:string):Promise<{signed_url:string;mime_type:"image/webp";expires_in:number}>;
};

type Client={rpc:(name:string,args?:Record<string,unknown>)=>PromiseLike<{data:unknown;error:{code?:string}|null}>;storage:{from:(bucket:string)=>{
  upload:(path:string,bytes:Buffer,options:Record<string,unknown>)=>PromiseLike<{data:unknown;error:unknown}>;
  remove:(paths:string[])=>PromiseLike<{data:unknown;error:unknown}>;
  createSignedUrl:(path:string,seconds:number)=>PromiseLike<{data:{signedUrl?:string}|null;error:unknown}>;
}}};
const clientOptions={auth:{autoRefreshToken:false,detectSessionInUrl:false,persistSession:false}} as const;
const hash=(bytes:Buffer)=>createHash("sha256").update(bytes).digest("hex");

async function normalize(bytes:Buffer,declaredMime:string){
  if(bytes.length===0||bytes.length>MAX_TRAINING_MEDIA_SOURCE_BYTES||!(["image/jpeg","image/png","image/webp"] as string[]).includes(declaredMime))throw new TrainingMediaInputError();
  try{
    const decoder=sharp(bytes,{failOn:"error",limitInputPixels:MAX_TRAINING_MEDIA_PIXELS,animated:true});
    const metadata=await decoder.metadata();
    const detected=metadata.format==="jpeg"?"image/jpeg":metadata.format==="png"?"image/png":metadata.format==="webp"?"image/webp":null;
    if(!detected||detected!==declaredMime||!metadata.width||!metadata.height||(metadata.pages??1)>1)throw new TrainingMediaInputError();
    const pixels=metadata.width*metadata.height;
    const long=Math.max(metadata.width,metadata.height),short=Math.min(metadata.width,metadata.height);
    if(pixels>MAX_TRAINING_MEDIA_PIXELS||long<TRAINING_MEDIA_MIN_LONG_EDGE||short<TRAINING_MEDIA_MIN_SHORT_EDGE)throw new TrainingMediaInputError();
    const output=await sharp(bytes,{failOn:"error",limitInputPixels:MAX_TRAINING_MEDIA_PIXELS})
      .rotate().resize({width:MAX_STORED_LONG_EDGE,height:MAX_STORED_LONG_EDGE,fit:"inside",withoutEnlargement:true})
      .webp({quality:83,alphaQuality:90,effort:5}).toBuffer({resolveWithObject:true});
    if(!output.info.width||!output.info.height||output.data.length===0||output.data.length>MAX_TRAINING_MEDIA_SOURCE_BYTES)throw new TrainingMediaInputError();
    return{bytes:output.data,width:output.info.width,height:output.info.height,sha256:hash(output.data),sourceMime:detected,sourceBytes:bytes.length,sourceSha256:hash(bytes)};
  }catch(error){if(error instanceof TrainingMediaInputError)throw error;throw new TrainingMediaInputError();}
}

export function createTrainingMediaService(url:string,secretKey:string){
  return createTrainingMediaServiceFromClient(createClient(url,secretKey,clientOptions) as unknown as Client);
}
export function createTrainingMediaServiceFromClient(client:Client):TrainingMediaService{
  const storage=client.storage.from(TRAINING_MEDIA_BUCKET);
  async function rpc(name:string,args:Record<string,unknown>){const result=await client.rpc(name,args);if(result.error){
    if(result.error.code==="42501")throw new TrainingMediaAccessError();
    if(result.error.code==="22023")throw new TrainingMediaInputError();
    if(result.error.code==="23505"||result.error.code==="55000")throw new TrainingMediaConflictError();
    if(result.error.code==="P0002")throw new TrainingMediaNotFoundError();
    throw new TrainingMediaUnavailableError();}return result.data;}
  const args=(scope:Omit<Scope,"requestId">)=>({actor_user_id:scope.actorUserId,target_organization_id:scope.organizationId,target_course_id:scope.courseId,target_course_version_id:scope.courseVersionId});
  const preview=(scope:Omit<Scope,"requestId">,row:z.infer<typeof mediaRow>):TrainingMediaDto=>({...row,preview_url:`/api/internal-admin/training/media/${row.id}?organization=${scope.organizationId}&course=${scope.courseId}&version=${scope.courseVersionId}`});
  const slotPreview=(scope:Omit<Scope,"requestId">,row:z.infer<typeof trainingImageSlotRowSchema>):TrainingImageSlotDto=>({...row,preview_url:row.preview_available&&row.media_id?`/api/internal-admin/training/media/${row.media_id}?organization=${scope.organizationId}&course=${scope.courseId}&version=${scope.courseVersionId}`:null});
  const log=(stage:string,outcome:string,safeCategory:string,sourceMime?:string,sourceBytes?:number,storedBytes?:number)=>console.warn("TRAINING_MEDIA_UPLOAD",{stage,outcome,safeCategory,sourceMime,sourceBytes,storedBytes});
  async function remove(path:string,stage:string){const result=await storage.remove([path]);if(result.error){log("cleanup","failed",stage);return false;}return true;}
  async function upload(scope:Scope,mediaId:string,source:Buffer,declaredMime:string){
    let normalized;try{normalized=await normalize(source,declaredMime);}catch(error){log("decode","rejected","invalid_image",declaredMime,source.length);throw error;}
    const path=`organizations/${scope.organizationId}/courses/${scope.courseId}/versions/${scope.courseVersionId}/assets/${mediaId}/${randomUUID()}.webp`;
    const result=await storage.upload(path,normalized.bytes,{contentType:"image/webp",cacheControl:"300",upsert:false});
    if(result.error){log("storage_upload","failed","storage_unavailable",declaredMime,source.length,normalized.bytes.length);throw new TrainingMediaUnavailableError();}
    return{...normalized,path};
  }
  return{
    async listDraftVersions(actorUserId,organizationId){return z.array(draftVersionRow).parse(await rpc("list_internal_admin_training_draft_versions",{actor_user_id:actorUserId,target_organization_id:organizationId}));},
    async list(scope){return z.array(mediaRow).parse(await rpc("list_internal_admin_training_media",args(scope))).map(row=>preview(scope,row));},
    async listSlots(scope){return z.array(trainingImageSlotRowSchema).parse(await rpc("list_internal_admin_training_image_slots",args(scope))).map(row=>slotPreview(scope,row));},
    async create(scope,input){
      const metadata=trainingMediaMetadataSchema.parse({asset_key:input.asset_key,title_i18n:input.title_i18n,alt_i18n:input.alt_i18n}),mediaId=randomUUID();const saved=await upload(scope,mediaId,input.bytes,input.declaredMime);
      try{const rows=z.array(mediaRow).max(1).parse(await rpc("register_internal_admin_training_media",{...args(scope),target_media_id:mediaId,target_asset_key:metadata.asset_key,new_title_i18n:metadata.title_i18n,new_alt_i18n:metadata.alt_i18n,new_storage_object_path:saved.path,new_byte_size:saved.bytes.length,new_width:saved.width,new_height:saved.height,new_sha256:saved.sha256,new_source_mime_type:saved.sourceMime,new_source_byte_size:saved.sourceBytes,new_source_sha256:saved.sourceSha256}));if(!rows[0])throw new TrainingMediaUnavailableError();return preview(scope,rows[0]);}
      catch(error){await remove(saved.path,"db_register_compensation");throw error;}
    },
    async replace(scope,input){
      uuid.parse(input.assetId);const metadata=trainingMediaMetadataSchema.parse({asset_key:input.asset_key,title_i18n:input.title_i18n,alt_i18n:input.alt_i18n}),saved=await upload(scope,input.assetId,input.bytes,input.declaredMime);
      try{const rows=z.array(z.object({id:uuid,old_storage_object_path:z.string(),storage_object_path:z.string()}).strict()).max(1).parse(await rpc("replace_internal_admin_training_media",{...args(scope),target_media_id:input.assetId,new_storage_object_path:saved.path,new_title_i18n:metadata.title_i18n,new_alt_i18n:metadata.alt_i18n,new_byte_size:saved.bytes.length,new_width:saved.width,new_height:saved.height,new_sha256:saved.sha256,new_source_mime_type:saved.sourceMime,new_source_byte_size:saved.sourceBytes,new_source_sha256:saved.sourceSha256}));if(!rows[0])throw new TrainingMediaUnavailableError();await remove(rows[0].old_storage_object_path,"replace_old_object");const current=(await this.list(scope)).find(item=>item.id===input.assetId);if(!current)throw new TrainingMediaUnavailableError();return current;}
      catch(error){await remove(saved.path,"replace_compensation");throw error;}
    },
    async updateMetadata(scope,input){uuid.parse(input.assetId);const metadata=trainingMediaMetadataSchema.parse({asset_key:input.asset_key,title_i18n:input.title_i18n,alt_i18n:input.alt_i18n});const rows=z.array(mediaRow).max(1).parse(await rpc("update_internal_admin_training_media_metadata",{...args(scope),target_media_id:input.assetId,new_title_i18n:metadata.title_i18n,new_alt_i18n:metadata.alt_i18n}));if(!rows[0])throw new TrainingMediaNotFoundError();return preview(scope,rows[0]);},
    async retire(scope,assetId){uuid.parse(assetId);const rows=z.array(z.object({id:uuid,retired_storage_object_path:z.string()}).strict()).max(1).parse(await rpc("retire_internal_admin_training_media",{...args(scope),target_media_id:assetId}));if(!rows[0])throw new TrainingMediaNotFoundError();await remove(rows[0].retired_storage_object_path,"retire_object");},
    async authorizeAdminRead(scope,assetId){uuid.parse(assetId);const rows=z.array(storageRow).max(1).parse(await rpc("authorize_internal_admin_training_media_read",{...args(scope),target_media_id:assetId}));if(!rows[0])throw new TrainingMediaNotFoundError();const signed=await storage.createSignedUrl(rows[0].storage_object_path,TRAINING_MEDIA_SIGNED_URL_SECONDS);if(signed.error||!signed.data?.signedUrl)throw new TrainingMediaUnavailableError();return{signed_url:signed.data.signedUrl,mime_type:"image/webp",expires_in:TRAINING_MEDIA_SIGNED_URL_SECONDS};},
  };
}

export const TRAINING_MEDIA_LOCALES=locales;
