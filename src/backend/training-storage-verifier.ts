import {createHash,randomUUID} from "node:crypto";
import {createClient} from "@supabase/supabase-js";
import sharp from "sharp";
import {z} from "zod";
import {MAX_TRAINING_MEDIA_PIXELS,MAX_TRAINING_MEDIA_SOURCE_BYTES,TRAINING_MEDIA_BUCKET} from "./training-media";
import {TRAINING_PUBLICATION_PROTOCOL_VERSION,verifyTrainingPublicationAuthorization,type TrainingPublicationAuthorization} from "./training-publication-authorization";

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
export type TrainingVerifierJobRow=z.infer<typeof jobRowSchema>;
export type TrainingVerifierObservation={media_id:string;sha256:string;byte_size:number;width:number;height:number};
export type TrainingVerifierDatabase={
  claim():Promise<TrainingVerifierJobRow[]>;
  fail(publicationRequestId:string,leaseToken:string,failureCode:string,retryable:boolean):Promise<void>;
  blockAfterSourceVerification(publicationRequestId:string,leaseToken:string,observations:TrainingVerifierObservation[]):Promise<void>;
};
export type TrainingVerifierStorage={download(bucket:string,path:string):Promise<{bytes:Buffer;mimeType:string}>};
export type TrainingVerifierKeys={audience:string;publicKeysById:Readonly<Record<string,string>>};

export class TrainingVerifierRejectedError extends Error{}
export class TrainingVerifierUnavailableError extends Error{}

function expectedPath(row:TrainingVerifierJobRow,envelope:TrainingPublicationAuthorization){
  const prefix=`organizations/${envelope.organization_id}/courses/${envelope.course_id}/versions/${envelope.course_version_id}/assets/${row.media_id}/`;
  return row.storage_object_path.startsWith(prefix)&&new RegExp(`^${prefix}[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\\.webp$`,`i`).test(row.storage_object_path);
}

function hasWebpSignature(bytes:Buffer){
  return bytes.length>=12&&bytes.subarray(0,4).toString("ascii")==="RIFF"&&bytes.subarray(8,12).toString("ascii")==="WEBP";
}

export async function inspectTrainingStorageObject(
  row:TrainingVerifierJobRow,envelope:TrainingPublicationAuthorization,downloaded:{bytes:Buffer;mimeType:string},
):Promise<TrainingVerifierObservation>{
  if(row.storage_bucket!==TRAINING_MEDIA_BUCKET||!expectedPath(row,envelope)||downloaded.mimeType!=="image/webp"
    ||!hasWebpSignature(downloaded.bytes)||downloaded.bytes.length===0
    ||downloaded.bytes.length>MAX_TRAINING_MEDIA_SOURCE_BYTES||downloaded.bytes.length!==row.expected_byte_size)
    throw new TrainingVerifierRejectedError();
  const digest=createHash("sha256").update(downloaded.bytes).digest("hex");
  if(digest!==row.expected_sha256)throw new TrainingVerifierRejectedError();
  try{
    const metadata=await sharp(downloaded.bytes,{failOn:"error",limitInputPixels:MAX_TRAINING_MEDIA_PIXELS,
      animated:true,sequentialRead:true}).metadata();
    if(metadata.format!=="webp"||!metadata.width||!metadata.height||(metadata.pages??1)!==1
      ||metadata.width!==row.expected_width||metadata.height!==row.expected_height
      ||metadata.width*metadata.height>MAX_TRAINING_MEDIA_PIXELS||metadata.exif||metadata.xmp||metadata.icc||metadata.iptc)
      throw new TrainingVerifierRejectedError();
    return{media_id:row.media_id,sha256:digest,byte_size:downloaded.bytes.length,width:metadata.width,height:metadata.height};
  }catch(error){if(error instanceof TrainingVerifierRejectedError)throw error;throw new TrainingVerifierRejectedError();}
}

function verifyJob(rows:TrainingVerifierJobRow[],keys:TrainingVerifierKeys,now:Date){
  if(rows.length!==40||new Set(rows.map(row=>row.media_id)).size!==40)throw new TrainingVerifierRejectedError();
  const first=rows[0]!;
  if(rows.some(row=>row.publication_request_id!==first.publication_request_id||row.lease_token!==first.lease_token
    ||row.lease_expires_at.getTime()!==first.lease_expires_at.getTime()
    ||row.authorization_signature!==first.authorization_signature
    ||JSON.stringify(row.authorization_envelope)!==JSON.stringify(first.authorization_envelope)))
    throw new TrainingVerifierRejectedError();
  const envelope=first.authorization_envelope,nowSeconds=Math.floor(now.getTime()/1000);
  const publicKey=keys.publicKeysById[envelope.key_id];
  if(keys.audience!==envelope.audience||!publicKey||envelope.verification_run_id.length===0
    ||envelope.expires_at_epoch_seconds<=envelope.issued_at_epoch_seconds
    ||nowSeconds<envelope.issued_at_epoch_seconds-15||nowSeconds>=envelope.expires_at_epoch_seconds
    ||now>=first.lease_expires_at
    ||!verifyTrainingPublicationAuthorization(envelope,first.authorization_signature,publicKey))
    throw new TrainingVerifierRejectedError();
  return first;
}

async function inspectWithConcurrency(rows:TrainingVerifierJobRow[],storage:TrainingVerifierStorage,envelope:TrainingPublicationAuthorization){
  const observations=new Array<TrainingVerifierObservation>(rows.length);let next=0;
  await Promise.all(Array.from({length:Math.min(2,rows.length)},async()=>{
    for(;;){
      const index=next++;if(index>=rows.length)return;const row=rows[index]!;
      let downloaded:{bytes:Buffer;mimeType:string};
      try{downloaded=await storage.download(row.storage_bucket,row.storage_object_path);}
      catch(error){if(error instanceof TrainingVerifierRejectedError)throw error;throw new TrainingVerifierUnavailableError();}
      observations[index]=await inspectTrainingStorageObject(row,envelope,downloaded);
    }
  }));
  return observations;
}

export async function processTrainingVerifierJob(
  database:TrainingVerifierDatabase,storage:TrainingVerifierStorage,keys:TrainingVerifierKeys,now=()=>new Date(),
){
  const rows=z.array(jobRowSchema).parse(await database.claim());
  if(rows.length===0)return false;
  const first=rows[0]!;
  try{
    verifyJob(rows,keys,now());
    const observations=await inspectWithConcurrency(rows,storage,first.authorization_envelope);
    await database.blockAfterSourceVerification(first.publication_request_id,first.lease_token,observations);
    return true;
  }catch(error){
    const rejected=error instanceof TrainingVerifierRejectedError;
    try{await database.fail(first.publication_request_id,first.lease_token,
      rejected?"source_verification_rejected":"source_verification_unavailable",!rejected);}
    catch{/* A stale lease or concurrent terminal transition is already auditable in the database. */}
    throw error;
  }
}

type RpcClient={rpc:(name:string,args:Record<string,unknown>)=>PromiseLike<{data:unknown;error:{code?:string}|null}>};
export function createTrainingVerifierDatabase(client:RpcClient,config:{capabilityId:string;capabilitySecret:string;audience:string;workerInstanceId:string}):TrainingVerifierDatabase{
  async function rpc(name:string,args:Record<string,unknown>){const result=await client.rpc(name,args);if(result.error)throw new TrainingVerifierUnavailableError();return result.data;}
  const capability=()=>({target_capability_id:config.capabilityId,capability_secret:config.capabilitySecret,expected_audience:config.audience});
  return{
    async claim(){return z.array(jobRowSchema).parse(await rpc("claim_training_storage_verifier_job",{
      ...capability(),worker_instance_id:config.workerInstanceId,claim_request_id:randomUUID(),
    }));},
    async fail(id,leaseToken,failureCode,retryable){await rpc("fail_training_storage_verifier_job",{
      ...capability(),target_publication_request_id:id,target_lease_token:leaseToken,failure_code:failureCode,
      retryable,failure_request_id:randomUUID(),
    });},
    async blockAfterSourceVerification(id,leaseToken,observations){await rpc(
      "block_training_storage_verifier_job_after_source_verification",{
        ...capability(),target_publication_request_id:id,target_lease_token:leaseToken,
        observed_objects:observations,completion_request_id:randomUUID(),
      },
    );},
  };
}

export function createTrainingVerifierBrokerClient(url:string,publishableKey:string){
  return createClient(url,publishableKey,{auth:{autoRefreshToken:false,detectSessionInUrl:false,persistSession:false}}) as unknown as RpcClient;
}

export function createTrainingVerifierStorage(config:{url:string;publishableKey:string;accessToken:string;timeoutMs:number}):TrainingVerifierStorage{
  const origin=new URL(config.url);if(!["http:","https:"].includes(origin.protocol))throw new Error("Invalid Storage origin.");
  return{async download(bucket,path){
    if(bucket!==TRAINING_MEDIA_BUCKET||path.startsWith("/")||path.includes("\\")||path.split("/").some(part=>!part||part==="."||part===".."))
      throw new TrainingVerifierRejectedError();
    const encodedPath=path.split("/").map(encodeURIComponent).join("/");
    const target=new URL(`/storage/v1/object/authenticated/${encodeURIComponent(bucket)}/${encodedPath}`,origin);
    if(target.origin!==origin.origin)throw new TrainingVerifierRejectedError();
    const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),config.timeoutMs);
    try{
      const response=await fetch(target,{headers:{apikey:config.publishableKey,Authorization:`Bearer ${config.accessToken}`},
        redirect:"error",signal:controller.signal});
      if(!response.ok||!response.body)throw new TrainingVerifierUnavailableError();
      const declared=response.headers.get("content-length");
      if(declared&&(!/^\d+$/.test(declared)||Number(declared)>MAX_TRAINING_MEDIA_SOURCE_BYTES)){
        await response.body.cancel();throw new TrainingVerifierRejectedError();
      }
      const reader=response.body.getReader(),chunks:Buffer[]=[];let total=0,chunkCount=0;
      for(;;){const item=await reader.read();if(item.done)break;total+=item.value.byteLength;
        chunkCount+=1;if(total>MAX_TRAINING_MEDIA_SOURCE_BYTES||chunkCount>8192){await reader.cancel();throw new TrainingVerifierRejectedError();}
        chunks.push(Buffer.from(item.value));}
      return{bytes:Buffer.concat(chunks,total),mimeType:(response.headers.get("content-type")??"").split(";",1)[0]!.trim().toLowerCase()};
    }catch(error){
      if(error instanceof TrainingVerifierRejectedError||error instanceof TrainingVerifierUnavailableError)throw error;
      throw new TrainingVerifierUnavailableError();
    }finally{clearTimeout(timer);}
  }};
}
