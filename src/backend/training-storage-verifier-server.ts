import {randomUUID} from "node:crypto";
import {z} from "zod";
import {createTrainingVerifierBrokerClient,createTrainingVerifierDatabase,createTrainingVerifierStorage,processTrainingIntegrityAudit,processTrainingVerifierJob} from "./training-storage-verifier";

const publicKeysSchema=z.record(z.string().regex(/^[A-Za-z0-9._-]{1,64}$/),z.string().min(1));
const environmentSchema=z.object({
  TRAINING_VERIFIER_SUPABASE_URL:z.url(),
  TRAINING_VERIFIER_SUPABASE_PUBLISHABLE_KEY:z.string().min(1),
  TRAINING_VERIFIER_STORAGE_ACCESS_TOKEN:z.string().min(32),
  TRAINING_VERIFIER_CAPABILITY_ID:z.uuid(),
  TRAINING_VERIFIER_CAPABILITY_SECRET:z.string().min(43).max(256),
  TRAINING_PUBLICATION_AUDIENCE:z.string().regex(/^[a-z0-9][a-z0-9._:/-]{2,127}$/),
  TRAINING_PUBLICATION_SIGNING_PUBLIC_KEYS_BASE64_JSON:z.string().min(1),
  TRAINING_VERIFIER_POLL_INTERVAL_MS:z.coerce.number().int().min(1000).max(60000).default(5000),
  TRAINING_VERIFIER_DOWNLOAD_TIMEOUT_MS:z.coerce.number().int().min(1000).max(30000).default(10000),
}).parse(process.env);

let encodedKeys:unknown;
try{encodedKeys=JSON.parse(Buffer.from(environmentSchema.TRAINING_PUBLICATION_SIGNING_PUBLIC_KEYS_BASE64_JSON,"base64").toString("utf8"));}
catch{throw new Error("Invalid Training verifier public-key configuration.");}
const publicKeysById=Object.fromEntries(Object.entries(publicKeysSchema.parse(encodedKeys))
  .map(([keyId,pemBase64])=>[keyId,Buffer.from(pemBase64,"base64").toString("utf8")]));
const client=createTrainingVerifierBrokerClient(environmentSchema.TRAINING_VERIFIER_SUPABASE_URL,
  environmentSchema.TRAINING_VERIFIER_SUPABASE_PUBLISHABLE_KEY);
const database=createTrainingVerifierDatabase(client,{
  capabilityId:environmentSchema.TRAINING_VERIFIER_CAPABILITY_ID,
  capabilitySecret:environmentSchema.TRAINING_VERIFIER_CAPABILITY_SECRET,
  audience:environmentSchema.TRAINING_PUBLICATION_AUDIENCE,workerInstanceId:randomUUID(),
});
const storage=createTrainingVerifierStorage({
  url:environmentSchema.TRAINING_VERIFIER_SUPABASE_URL,
  publishableKey:environmentSchema.TRAINING_VERIFIER_SUPABASE_PUBLISHABLE_KEY,
  accessToken:environmentSchema.TRAINING_VERIFIER_STORAGE_ACCESS_TOKEN,
  timeoutMs:environmentSchema.TRAINING_VERIFIER_DOWNLOAD_TIMEOUT_MS,
});
let stopping=false;
async function run(){while(!stopping){try{
    const processed=await processTrainingVerifierJob(database,storage,{audience:environmentSchema.TRAINING_PUBLICATION_AUDIENCE,publicKeysById})
      ||await processTrainingIntegrityAudit(database,storage);
  if(!processed)await new Promise(resolve=>setTimeout(resolve,environmentSchema.TRAINING_VERIFIER_POLL_INTERVAL_MS));
}catch(error){
  console.error("TRAINING_STORAGE_VERIFIER",{outcome:"rejected_or_unavailable",errorType:error instanceof Error?error.name:"UnknownError"});
  await new Promise(resolve=>setTimeout(resolve,environmentSchema.TRAINING_VERIFIER_POLL_INTERVAL_MS));
}}}
for(const signal of ["SIGINT","SIGTERM"] as const)process.once(signal,()=>{stopping=true;});
void run().catch(error=>{console.error("Training verifier stopped",{errorType:error instanceof Error?error.name:"UnknownError"});process.exitCode=1;});
