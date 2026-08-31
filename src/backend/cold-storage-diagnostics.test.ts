import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { describe, it } from "node:test";
import type { Request, Response } from "express";
import { attachColdStorageDraftRequestLifecycle } from "./app";
import { ChecklistConflictError, runColdStorageDraftRpc, type ColdStorageDraftDiagnosticContext, type ColdStorageDraftDiagnosticEvent } from "./checklist-persistence";

const context:ColdStorageDraftDiagnosticContext={
 backendRequestId:"request-1",
 correlationId:"62000000-0000-4000-8000-000000000001",
 clientInstanceId:"62000000-0000-4000-8000-000000000002",
 eventSource:"temperature_blur",
 actorUserId:"12000000-0000-4000-8000-000000000001",
 branchId:"22000000-0000-4000-8000-000000000001",
 expectedRevision:7,
 frontendRelease:null,
 backendRelease:null,
 userAgent:"safe-agent",
 origin:"https://app.example.test",
 referer:"https://app.example.test/branch-manager",
 containerId:"container-1",
 processId:123,
};

describe("Cold Storage draft diagnostics",()=>{
 it("records RPC start and successful end without payload fields",async()=>{
  const events:ColdStorageDraftDiagnosticEvent[]=[];
  const data=await runColdStorageDraftRpc(async()=>({data:{revision:8},error:null}),{context,log:(event)=>events.push(event)});
  assert.deepEqual(data,{revision:8});
  assert.deepEqual(events.map(event=>event.event),["cold_storage_draft_rpc_start","cold_storage_draft_rpc_end"]);
  assert.equal(events[1]?.outcome,"success");
  assert.equal(typeof events[1]?.durationMs,"number");
  const serialized=JSON.stringify(events);
  assert.doesNotMatch(serialized,/temperature_c|corrective_action|equipment|secret note|authorization|cookie/i);
 });

 it("preserves SQLSTATE on RPC failure without changing conflict behavior",async()=>{
  const events:ColdStorageDraftDiagnosticEvent[]=[];
  await assert.rejects(
   ()=>runColdStorageDraftRpc(async()=>({data:null,error:{code:"40001"}}),{context:{...context,eventSource:"remarks_blur"},log:(event)=>events.push(event)}),
   (error:unknown)=>error instanceof ChecklistConflictError&&error.sqlstate==="40001",
  );
  assert.deepEqual(events.map(event=>event.event),["cold_storage_draft_rpc_start","cold_storage_draft_rpc_end"]);
  assert.equal(events[1]?.outcome,"error");
  assert.equal(events[1]?.errorCode,"40001");
 });

 it("sanitizes untrusted RPC error codes",async()=>{
  const events:ColdStorageDraftDiagnosticEvent[]=[];
  await assert.rejects(
   ()=>runColdStorageDraftRpc(async()=>({data:null,error:{code:"unsafe code: payload"}}),{context,log:(event)=>events.push(event)}),
   /Checklist persistence unavailable/,
  );
  assert.equal(events[1]?.errorCode,null);
 });

 it("does not let diagnostic logger failures affect a successful RPC",async()=>{
  const data=await runColdStorageDraftRpc(async()=>({data:"saved",error:null}),{context,log:()=>{throw new Error("logger unavailable");}});
  assert.equal(data,"saved");
 });

 it("records abort, premature close, and finish lifecycle events without throwing",()=>{
  const requestEmitter=new EventEmitter(),responseEmitter=new EventEmitter();
  const responseState={statusCode:200,writableFinished:false};
  const response=new Proxy(responseEmitter,{get(target,property){if(property in responseState)return responseState[property as keyof typeof responseState];return Reflect.get(target,property);}}) as unknown as Response;
  const events:ColdStorageDraftDiagnosticEvent[]=[];
  attachColdStorageDraftRequestLifecycle(requestEmitter as unknown as Request,response,context,(event)=>events.push(event));
  assert.doesNotThrow(()=>requestEmitter.emit("aborted"));
  assert.doesNotThrow(()=>responseEmitter.emit("close"));
  responseState.writableFinished=true;
  assert.doesNotThrow(()=>responseEmitter.emit("finish"));
  assert.deepEqual(events.map(event=>event.event),["cold_storage_request_aborted","cold_storage_response_closed","cold_storage_response_finished"]);
 });
});
