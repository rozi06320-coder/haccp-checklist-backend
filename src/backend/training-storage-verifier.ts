import {createHash,randomUUID} from "node:crypto";
import {createClient} from "@supabase/supabase-js";
import sharp from "sharp";
import {z} from "zod";
import {MAX_TRAINING_MEDIA_PIXELS,MAX_TRAINING_MEDIA_SOURCE_BYTES,TRAINING_MEDIA_BUCKET} from "./training-media";
import {TRAINING_PUBLICATION_PROTOCOL_VERSION,verifyTrainingPublicationAuthorization,type TrainingPublicationAuthorization} from "./training-publication-authorization";

export const TRAINING_PUBLISHED_MEDIA_BUCKET="training-published-media" as const;
const uuid=z.uuid(),sha=z.string().regex(/^[0-9a-f]{64}$/);
const authorizationSchema=z.object({
  protocol_version:z.literal(TRAINING_PUBLICATION_PROTOCOL_VERSION),
  audience:z.string().regex(/^[a-z0-9][a-z0-9._:/-]{2,127}$/),key_id:z.string().regex(/^[A-Za-z0-9._-]{1,64}$/),
  actor_user_id:uuid,organization_id:uuid,course_id:uuid,course_version_id:uuid,
  submission_id:uuid,verification_run_id:uuid,challenge_nonce:uuid,
  issued_at_epoch_seconds:z.number().int().positive(),expires_at_epoch_seconds:z.number().int().positive(),
  expected_revision:z.number().int().nonnegative(),expected_content_fingerprint:sha,action_request_id:uuid,
}).strict();
const jobRowSchema=z.object({
  publication_request_id:uuid,lease_token:uuid,lease_expires_at:z.coerce.date(),
  authorization_envelope:authorizationSchema,authorization_signature:z.string().regex(/^[A-Za-z0-9+/]{86}==$/),
  media_id:uuid,media_revision:z.number().int().positive(),storage_bucket:z.literal(TRAINING_MEDIA_BUCKET),
  storage_object_path:z.string().min(1).max(1024),expected_sha256:sha,
  expected_byte_size:z.number().int().positive().max(MAX_TRAINING_MEDIA_SOURCE_BYTES),
  expected_width:z.number().int().positive(),expected_height:z.number().int().positive(),
}).strict();
const integrityJobRowSchema=z.object({
  manifest_id:uuid,lease_token:uuid,lease_expires_at:z.coerce.date(),media_id:uuid,expected_sha256:sha,
  expected_byte_size:z.number().int().positive().max(MAX_TRAINING_MEDIA_SOURCE_BYTES),
  expected_width:z.number().int().positive(),expected_height:z.number().int().positive(),
  storage_bucket:z.literal(TRAINING_PUBLISHED_MEDIA_BUCKET),storage_object_path:z.string().min(1).max(1024),
}).strict();
export type TrainingVerifierJobRow=z.infer<typeof jobRowSchema>;
export type TrainingIntegrityJobRow=z.infer<typeof integrityJobRowSchema>;
export type TrainingVerifierObservation={media_id:string;sha256:string;byte_size:number;width:number;height:number};
export type TrainingPublishedManifestItem=TrainingVerifierObservation&{media_revision:number;object_path:string};
export type TrainingVerifierDatabase={
  claim():Promise<TrainingVerifierJobRow[]>;
  renew(publicationRequestId:string,leaseToken:string):Promise<void>;
  fail(publicationRequestId:string,leaseToken:string,failureCode:string,retryable:boolean):Promise<void>;
  finalize(publicationRequestId:string,leaseToken:string,observations:TrainingVerifierObservation[],items:TrainingPublishedManifestItem[],manifestFingerprint:string):Promise<void>;
  claimIntegrity():Promise<TrainingIntegrityJobRow[]>;
  completeIntegrity(manifestId:string,leaseToken:string,status:"passed"|"failed",observations:TrainingVerifierObservation[],failureCode:string|null):Promise<void>;
};
export type TrainingVerifierStorage={
  download(bucket:string,path:string):Promise<{bytes:Buffer;mimeType:string}>;
  uploadImmutable(bucket:string,path:string,bytes:Buffer):Promise<"created"|"exists">;
};
export type TrainingVerifierKeys={audience:string;publicKeysById:Readonly<Record<string,string>>};

export class TrainingVerifierRejectedError extends Error{}
export class TrainingVerifierUnavailableError extends Error{}
class TrainingVerifierDestinationRejectedError extends TrainingVerifierRejectedError{}
class TrainingVerifierDestinationUnavailableError extends TrainingVerifierUnavailableError{}

function expectedSourcePath(row:TrainingVerifierJobRow,envelope:TrainingPublicationAuthorization){
  const prefix=`organizations/${envelope.organization_id}/courses/${envelope.course_id}/versions/${envelope.course_version_id}/assets/${row.media_id}/`;
  return row.storage_object_path.startsWith(prefix)&&new RegExp(`^${prefix}[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\\.webp$`,`i`).test(row.storage_object_path);
}
function publishedPath(digest:string){return`sha256/${digest.slice(0,2)}/${digest}.webp`;}
function hasWebpSignature(bytes:Buffer){return bytes.length>=12&&bytes.subarray(0,4).toString("ascii")==="RIFF"&&bytes.subarray(8,12).toString("ascii")==="WEBP";}

async function inspectBytes(expected:{media_id:string;expected_sha256:string;expected_byte_size:number;expected_width:number;expected_height:number},downloaded:{bytes:Buffer;mimeType:string}){
  if(downloaded.mimeType!=="image/webp"||!hasWebpSignature(downloaded.bytes)||downloaded.bytes.length===0
    ||downloaded.bytes.length>MAX_TRAINING_MEDIA_SOURCE_BYTES||downloaded.bytes.length!==expected.expected_byte_size)throw new TrainingVerifierRejectedError();
  const digest=createHash("sha256").update(downloaded.bytes).digest("hex");
  if(digest!==expected.expected_sha256)throw new TrainingVerifierRejectedError();
  try{
    const metadata=await sharp(downloaded.bytes,{failOn:"error",limitInputPixels:MAX_TRAINING_MEDIA_PIXELS,animated:true,sequentialRead:true}).metadata();
    if(metadata.format!=="webp"||!metadata.width||!metadata.height||(metadata.pages??1)!==1
      ||metadata.width!==expected.expected_width||metadata.height!==expected.expected_height
      ||metadata.width*metadata.height>MAX_TRAINING_MEDIA_PIXELS||metadata.exif||metadata.xmp||metadata.icc||metadata.iptc)
      throw new TrainingVerifierRejectedError();
    return{media_id:expected.media_id,sha256:digest,byte_size:downloaded.bytes.length,width:metadata.width,height:metadata.height};
  }catch(error){if(error instanceof TrainingVerifierRejectedError)throw error;throw new TrainingVerifierRejectedError();}
}

export async function inspectTrainingStorageObject(row:TrainingVerifierJobRow,envelope:TrainingPublicationAuthorization,downloaded:{bytes:Buffer;mimeType:string}){
  if(row.storage_bucket!==TRAINING_MEDIA_BUCKET||!expectedSourcePath(row,envelope))throw new TrainingVerifierRejectedError();
  return inspectBytes(row,downloaded);
}

function verifyJob(rows:TrainingVerifierJobRow[],keys:TrainingVerifierKeys,now:Date){
  if(rows.length!==40||new Set(rows.map(row=>row.media_id)).size!==40)throw new TrainingVerifierRejectedError();
  const first=rows[0]!;
  if(rows.some(row=>row.publication_request_id!==first.publication_request_id||row.lease_token!==first.lease_token
    ||row.lease_expires_at.getTime()!==first.lease_expires_at.getTime()||row.authorization_signature!==first.authorization_signature
    ||JSON.stringify(row.authorization_envelope)!==JSON.stringify(first.authorization_envelope)))throw new TrainingVerifierRejectedError();
  const envelope=first.authorization_envelope,nowSeconds=Math.floor(now.getTime()/1000),publicKey=keys.publicKeysById[envelope.key_id];
  if(keys.audience!==envelope.audience||!publicKey||envelope.expires_at_epoch_seconds<=envelope.issued_at_epoch_seconds
    ||nowSeconds<envelope.issued_at_epoch_seconds-15||nowSeconds>=envelope.expires_at_epoch_seconds||now>=first.lease_expires_at
    ||!verifyTrainingPublicationAuthorization(envelope,first.authorization_signature,publicKey))throw new TrainingVerifierRejectedError();
  return first;
}

export function trainingPublishedManifestFingerprint(envelope:TrainingPublicationAuthorization,items:TrainingPublishedManifestItem[]){
  const lines=[...items].sort((a,b)=>a.media_id.localeCompare(b.media_id)).map(item=>
    `${item.media_id}:${item.media_revision}:${item.sha256}:${item.byte_size}:${item.width}:${item.height}:${item.object_path}`);
  return createHash("sha256").update([
    "training-published-media-manifest-v1",envelope.organization_id,envelope.course_id,envelope.course_version_id,
    String(envelope.expected_revision),envelope.expected_content_fingerprint,...lines,
  ].join("\n")).digest("hex");
}

async function promoteAll(rows:TrainingVerifierJobRow[],database:TrainingVerifierDatabase,storage:TrainingVerifierStorage,envelope:TrainingPublicationAuthorization){
  const observations:TrainingVerifierObservation[]=[],items:TrainingPublishedManifestItem[]=[];
  for(let offset=0;offset<rows.length;offset+=2){
    if(offset%8===0)await database.renew(rows[0]!.publication_request_id,rows[0]!.lease_token);
    const promoted=await Promise.all(rows.slice(offset,offset+2).map(async row=>{
      let source:{bytes:Buffer;mimeType:string};
      try{source=await storage.download(row.storage_bucket,row.storage_object_path);}
      catch(error){if(error instanceof TrainingVerifierRejectedError)throw error;throw new TrainingVerifierUnavailableError();}
      const observation=await inspectTrainingStorageObject(row,envelope,source),objectPath=publishedPath(observation.sha256);
      try{
        await storage.uploadImmutable(TRAINING_PUBLISHED_MEDIA_BUCKET,objectPath,source.bytes);
        const destination=await storage.download(TRAINING_PUBLISHED_MEDIA_BUCKET,objectPath);
        const checked=await inspectBytes(row,destination);
        if(checked.sha256!==observation.sha256)throw new TrainingVerifierDestinationRejectedError();
      }catch(error){
        if(error instanceof TrainingVerifierDestinationRejectedError)throw error;
        if(error instanceof TrainingVerifierRejectedError)throw new TrainingVerifierDestinationRejectedError();
        throw new TrainingVerifierDestinationUnavailableError();
      }
      return{observation,item:{...observation,media_revision:row.media_revision,object_path:objectPath}};
    }));
    for(const result of promoted){observations.push(result.observation);items.push(result.item);}
  }
  return{observations,items};
}

export async function processTrainingVerifierJob(database:TrainingVerifierDatabase,storage:TrainingVerifierStorage,keys:TrainingVerifierKeys,now=()=>new Date()){
  const rows=z.array(jobRowSchema).parse(await database.claim());if(rows.length===0)return false;
  const first=rows[0]!;
  try{
    verifyJob(rows,keys,now());
    const promoted=await promoteAll(rows,database,storage,first.authorization_envelope);
    await database.renew(first.publication_request_id,first.lease_token);
    await database.finalize(first.publication_request_id,first.lease_token,promoted.observations,promoted.items,
      trainingPublishedManifestFingerprint(first.authorization_envelope,promoted.items));
    return true;
  }catch(error){
    const destination=error instanceof TrainingVerifierDestinationRejectedError||error instanceof TrainingVerifierDestinationUnavailableError;
    const rejected=error instanceof TrainingVerifierRejectedError;
    try{await database.fail(first.publication_request_id,first.lease_token,
      destination?(rejected?"destination_verification_rejected":"destination_verification_unavailable"):
        (rejected?"source_verification_rejected":"source_verification_unavailable"),!rejected);}catch{}
    throw error;
  }
}

export async function processTrainingIntegrityAudit(database:TrainingVerifierDatabase,storage:TrainingVerifierStorage){
  const rows=z.array(integrityJobRowSchema).parse(await database.claimIntegrity());if(rows.length===0)return false;
  const first=rows[0]!;
  try{
    if(rows.length!==40||new Set(rows.map(row=>row.media_id)).size!==40||rows.some(row=>row.manifest_id!==first.manifest_id
      ||row.lease_token!==first.lease_token||row.lease_expires_at.getTime()!==first.lease_expires_at.getTime()))throw new TrainingVerifierRejectedError();
    const observations:TrainingVerifierObservation[]=[];
    for(let offset=0;offset<rows.length;offset+=2){
      const checked=await Promise.all(rows.slice(offset,offset+2).map(async row=>{
        if(row.storage_object_path!==publishedPath(row.expected_sha256))throw new TrainingVerifierRejectedError();
        const downloaded=await storage.download(row.storage_bucket,row.storage_object_path);
        return inspectBytes(row,downloaded);
      }));observations.push(...checked);
    }
    await database.completeIntegrity(first.manifest_id,first.lease_token,"passed",observations,null);return true;
  }catch(error){
    const code=error instanceof TrainingVerifierRejectedError?"published_media_mismatch":"published_media_unavailable";
    try{await database.completeIntegrity(first.manifest_id,first.lease_token,"failed",[],code);}catch{}
    throw error;
  }
}

type RpcClient={rpc:(name:string,args:Record<string,unknown>)=>PromiseLike<{data:unknown;error:{code?:string}|null}>};
export function createTrainingVerifierDatabase(client:RpcClient,config:{capabilityId:string;capabilitySecret:string;audience:string;workerInstanceId:string}):TrainingVerifierDatabase{
  async function rpc(name:string,args:Record<string,unknown>){const result=await client.rpc(name,args);if(result.error)throw new TrainingVerifierUnavailableError();return result.data;}
  const capability=()=>({target_capability_id:config.capabilityId,capability_secret:config.capabilitySecret,expected_audience:config.audience});
  return{
    async claim(){return z.array(jobRowSchema).parse(await rpc("claim_training_storage_verifier_job",{...capability(),worker_instance_id:config.workerInstanceId,claim_request_id:randomUUID()}));},
    async renew(id,leaseToken){await rpc("renew_training_storage_verifier_job_lease",{...capability(),target_publication_request_id:id,target_lease_token:leaseToken,renewal_request_id:randomUUID()});},
    async fail(id,leaseToken,failureCode,retryable){await rpc("fail_training_storage_verifier_job",{...capability(),target_publication_request_id:id,target_lease_token:leaseToken,failure_code:failureCode,retryable,failure_request_id:randomUUID()});},
    async finalize(id,leaseToken,observations,items,manifestFingerprint){await rpc("finalize_training_storage_verifier_publication",{
      ...capability(),target_publication_request_id:id,target_lease_token:leaseToken,source_observed_objects:observations,
      published_manifest_items:items,expected_manifest_fingerprint:manifestFingerprint,completion_request_id:randomUUID(),
    });},
    async claimIntegrity(){return z.array(integrityJobRowSchema).parse(await rpc("claim_training_published_media_integrity_audit",{...capability(),worker_instance_id:config.workerInstanceId,claim_request_id:randomUUID()}));},
    async completeIntegrity(manifestId,leaseToken,status,observations,failureCode){await rpc("complete_training_published_media_integrity_audit",{
      ...capability(),target_manifest_id:manifestId,target_lease_token:leaseToken,audit_status:status,
      observed_objects:observations,failure_code:failureCode,completion_request_id:randomUUID(),
    });},
  };
}

export function createTrainingVerifierBrokerClient(url:string,publishableKey:string){
  return createClient(url,publishableKey,{auth:{autoRefreshToken:false,detectSessionInUrl:false,persistSession:false}}) as unknown as RpcClient;
}

export function createTrainingVerifierStorage(config:{url:string;publishableKey:string;accessToken:string;timeoutMs:number}):TrainingVerifierStorage{
  const origin=new URL(config.url);if(!["http:","https:"].includes(origin.protocol))throw new Error("Invalid Storage origin.");
  const validate=(bucket:string,path:string)=>{
    if(![TRAINING_MEDIA_BUCKET,TRAINING_PUBLISHED_MEDIA_BUCKET].includes(bucket as typeof TRAINING_MEDIA_BUCKET)
      ||path.startsWith("/")||path.includes("\\")||path.split("/").some(part=>!part||part==="."||part===".."))throw new TrainingVerifierRejectedError();
    if(bucket===TRAINING_PUBLISHED_MEDIA_BUCKET&&!/^sha256\/[0-9a-f]{2}\/[0-9a-f]{64}\.webp$/.test(path))throw new TrainingVerifierRejectedError();
    return path.split("/").map(encodeURIComponent).join("/");
  };
  const headers=()=>({apikey:config.publishableKey,Authorization:`Bearer ${config.accessToken}`});
  return{
    async download(bucket,path){
      const encodedPath=validate(bucket,path),target=new URL(`/storage/v1/object/authenticated/${encodeURIComponent(bucket)}/${encodedPath}`,origin);
      if(target.origin!==origin.origin)throw new TrainingVerifierRejectedError();
      const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),config.timeoutMs);
      try{
        const response=await fetch(target,{headers:headers(),redirect:"error",signal:controller.signal});
        if(!response.ok||!response.body)throw new TrainingVerifierUnavailableError();
        const declared=response.headers.get("content-length");
        if(declared&&(!/^\d+$/.test(declared)||Number(declared)>MAX_TRAINING_MEDIA_SOURCE_BYTES)){await response.body.cancel();throw new TrainingVerifierRejectedError();}
        const reader=response.body.getReader(),chunks:Buffer[]=[];let total=0,chunkCount=0;
        for(;;){const item=await reader.read();if(item.done)break;total+=item.value.byteLength;chunkCount+=1;
          if(total>MAX_TRAINING_MEDIA_SOURCE_BYTES||chunkCount>8192){await reader.cancel();throw new TrainingVerifierRejectedError();}chunks.push(Buffer.from(item.value));}
        return{bytes:Buffer.concat(chunks,total),mimeType:(response.headers.get("content-type")??"").split(";",1)[0]!.trim().toLowerCase()};
      }catch(error){if(error instanceof TrainingVerifierRejectedError||error instanceof TrainingVerifierUnavailableError)throw error;throw new TrainingVerifierUnavailableError();}
      finally{clearTimeout(timer);}
    },
    async uploadImmutable(bucket,path,bytes){
      if(bucket!==TRAINING_PUBLISHED_MEDIA_BUCKET||bytes.length===0||bytes.length>MAX_TRAINING_MEDIA_SOURCE_BYTES)throw new TrainingVerifierRejectedError();
      const encodedPath=validate(bucket,path),target=new URL(`/storage/v1/object/${encodeURIComponent(bucket)}/${encodedPath}`,origin);
      if(target.origin!==origin.origin)throw new TrainingVerifierRejectedError();
      const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),config.timeoutMs);
      try{
        const response=await fetch(target,{method:"POST",headers:{...headers(),"content-type":"image/webp","cache-control":"31536000","x-upsert":"false"},
          body:bytes,redirect:"error",signal:controller.signal});
        if(response.ok)return"created";if(response.status===400||response.status===409)return"exists";
        throw new TrainingVerifierUnavailableError();
      }catch(error){if(error instanceof TrainingVerifierRejectedError||error instanceof TrainingVerifierUnavailableError)throw error;throw new TrainingVerifierUnavailableError();}
      finally{clearTimeout(timer);}
    },
  };
}
