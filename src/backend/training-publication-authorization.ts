import {createPrivateKey,createPublicKey,sign,verify,type KeyObject} from "node:crypto";

export const TRAINING_PUBLICATION_PROTOCOL_VERSION=1 as const;

export type TrainingPublicationAuthorization={
  protocol_version:typeof TRAINING_PUBLICATION_PROTOCOL_VERSION;
  audience:string;
  key_id:string;
  actor_user_id:string;
  organization_id:string;
  course_id:string;
  course_version_id:string;
  submission_id:string;
  verification_run_id:string;
  challenge_nonce:string;
  issued_at_epoch_seconds:number;
  expires_at_epoch_seconds:number;
  expected_revision:number;
  expected_content_fingerprint:string;
  action_request_id:string;
};

function canonicalValue(value:unknown):unknown{
  if(Array.isArray(value))return value.map(canonicalValue);
  if(value&&typeof value==="object")return Object.fromEntries(
    Object.entries(value as Record<string,unknown>).sort(([left],[right])=>left<right?-1:left>right?1:0)
      .map(([key,item])=>[key,canonicalValue(item)]),
  );
  return value;
}

function requireEd25519(key:KeyObject){
  if(key.asymmetricKeyType!=="ed25519")throw new Error("Training publication signing key must be Ed25519.");
  return key;
}

function decodeCanonicalSignature(value:string){
  if(!/^[A-Za-z0-9+/]{86}==$/.test(value))return null;
  const decoded=Buffer.from(value,"base64");
  if(decoded.length!==64||decoded.toString("base64")!==value)return null;
  return decoded;
}

export function canonicalPublicationAuthorization(value:TrainingPublicationAuthorization){
  return Buffer.from(JSON.stringify(canonicalValue(value)),"utf8");
}

export function signTrainingPublicationAuthorization(value:TrainingPublicationAuthorization,privateKeyPem:string){
  const signature=sign(null,canonicalPublicationAuthorization(value),requireEd25519(createPrivateKey(privateKeyPem)));
  if(signature.length!==64)throw new Error("Invalid Ed25519 signature length.");
  return signature.toString("base64");
}

export function verifyTrainingPublicationAuthorization(
  value:TrainingPublicationAuthorization,signature:string,publicKeyPem:string,
){
  try{
    const decoded=decodeCanonicalSignature(signature);
    if(!decoded)return false;
    return verify(null,canonicalPublicationAuthorization(value),requireEd25519(createPublicKey(publicKeyPem)),decoded);
  }catch{return false;}
}
