import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  createStorageFetchWithDeadline,
  mapWithBoundedConcurrency,
  ProcessStorageLimiter,
  runWithStorageSignal,
  salesTrackingEvidenceStorageFailureAvailability,
} from "./checklist-persistence";
import {
  decodeSalesTrackingPeriodCursor,
  encodeSalesTrackingPeriodCursor,
} from "./sales-tracking-period-cursor";
import { managementSalesTrackingEvidenceRenewalItemSchema } from "../lib/contracts/management-sales-tracking-period";

const scope={
  organization_id:"36000000-0000-4000-8000-000000000001",
  branch_id:null,
  date_from:"2026-10-01",
  date_to:"2026-10-12",
};

describe("Sales Tracking period reporting helpers",()=>{
  it("round-trips only canonical cursors bound to the requested scope",()=>{
    const cursor=encodeSalesTrackingPeriodCursor({
      v:1,...scope,authority_revision:"36000000000000000000000000000001",business_date:"2026-10-05",
      item_branch_id:"26000000-0000-4000-8000-000000000001",
      report_id:"56000000-0000-4000-8000-000000000001",
      display_order:2,
      attachment_id:"76000000-0000-4000-8000-000000000001",
    });
    assert.equal(decodeSalesTrackingPeriodCursor(cursor,scope)?.display_order,2);
    assert.equal(decodeSalesTrackingPeriodCursor(cursor,scope)?.authority_revision,"36000000000000000000000000000001");
    assert.equal(decodeSalesTrackingPeriodCursor(cursor,{...scope,date_to:"2026-10-11"}),null);
    assert.equal(decodeSalesTrackingPeriodCursor(`${cursor}=`,scope),null);
    assert.equal(decodeSalesTrackingPeriodCursor("not-json",scope),null);
  });

  it("rejects cursors with missing, non-hex, or malformed authority revisions",()=>{
    assert.throws(()=>encodeSalesTrackingPeriodCursor({
      v:1,...scope,authority_revision:"not-a-valid-hex-revision",business_date:"2026-10-05",
      item_branch_id:"26000000-0000-4000-8000-000000000001",
      report_id:"56000000-0000-4000-8000-000000000001",
      display_order:1,attachment_id:"76000000-0000-4000-8000-000000000001",
    }));
  });

  it("preserves input order while limiting Storage work to six operations",async()=>{
    let active=0,maximum=0;
    const values=Array.from({length:50},(_,index)=>index);
    const results=await mapWithBoundedConcurrency(values,6,async(value)=>{
      active+=1;maximum=Math.max(maximum,active);
      await new Promise((resolve)=>setTimeout(resolve,2));
      active-=1;
      return value*2;
    });
    assert.equal(maximum,6);
    assert.deepEqual(results,values.map((value)=>value*2));
  });

  it("distinguishes missing Storage objects from transient signing failures without parsing messages",()=>{
    assert.equal(salesTrackingEvidenceStorageFailureAvailability({status:404}),"missing_object");
    assert.equal(salesTrackingEvidenceStorageFailureAvailability({originalError:{statusCode:"404"}}),"missing_object");
    assert.equal(salesTrackingEvidenceStorageFailureAvailability({status:503,message:"private path"}),"signing_unavailable");
    assert.equal(salesTrackingEvidenceStorageFailureAvailability(new Error("not found text is not trusted")),"signing_unavailable");
  });

  it("aborts hung Storage operations and cancels abandoned requests using real AbortSignal",async()=>{
    let underlyingSignalAborted = false;
    let abortReason: unknown = null;

    const mockFetch: typeof fetch = async (_input, init) => {
      const signal = init?.signal;
      if (signal) {
        signal.addEventListener("abort", () => {
          underlyingSignalAborted = true;
          abortReason = signal.reason;
        });
      }
      // Simulate hung request that never resolves unless aborted
      return new Promise<Response>((_resolve, reject) => {
        if (signal?.aborted) {
          reject(signal.reason);
          return;
        }
        signal?.addEventListener("abort", () => reject(signal.reason));
      });
    };

    const deadlineMs = 50;
    const storageFetch = createStorageFetchWithDeadline({
      baseFetch: mockFetch,
      deadlineMs,
      limiter: new ProcessStorageLimiter(5, 5),
    });

    // 1. Verify hung Storage request aborts when deadline triggers
    await assert.rejects(
      () => storageFetch("http://127.0.0.1:54321/storage/v1/object/info/bucket/photo.webp", {}),
      (err: unknown) => {
        assert.ok(err instanceof Error);
        assert.equal(underlyingSignalAborted, true);
        assert.match(String(err), /Storage operation deadline exceeded/);
        return true;
      }
    );

    // 2. Verify abandoned Storage request is cancelled immediately when external signal aborts
    underlyingSignalAborted = false;
    const clientController = new AbortController();
    const abandonPromise = runWithStorageSignal(clientController.signal, () =>
      storageFetch("http://127.0.0.1:54321/storage/v1/object/sign/bucket/photo.webp", {})
    );

    // Yield to let storageFetch reach mockFetch before aborting
    await new Promise((r) => setTimeout(r, 5));
    clientController.abort(new Error("Client disconnected"));
    await assert.rejects(
      abandonPromise,
      (err: unknown) => {
        assert.equal(underlyingSignalAborted, true);
        assert.match(String(err), /Client disconnected/);
        return true;
      }
    );
  });

  it("process-wide Storage limiter bounds concurrency and rejects when queue is saturated",async()=>{
    const limiter = new ProcessStorageLimiter(2, 2);
    let active = 0;
    let maxObserved = 0;

    const mockFetch: typeof fetch = async () => {
      active++;
      maxObserved = Math.max(maxObserved, active);
      await new Promise((r) => setTimeout(r, 20));
      active--;
      return new Response(JSON.stringify({ ok: true }));
    };

    const storageFetch = createStorageFetchWithDeadline({
      baseFetch: mockFetch,
      limiter,
      deadlineMs: 2000,
    });

    // Run 4 concurrent requests (2 active + 2 queued) -> all 4 should succeed bounded by 2
    const promises = Array.from({ length: 4 }, () =>
      storageFetch("http://127.0.0.1:54321/storage/v1/object/info/bucket/item", {})
    );

    // 5th request should be rejected immediately due to saturated queue
    await assert.rejects(
      () => storageFetch("http://127.0.0.1:54321/storage/v1/object/info/bucket/item", {}),
      /queue saturated/
    );

    await Promise.all(promises);
    assert.equal(maxObserved, 2);
    assert.equal(limiter.stats.active, 0);
  });

  it("cancellable Storage limiter queue removes aborted requests immediately and prevents double-release", async () => {
    const limiter = new ProcessStorageLimiter(1, 2);
    const release1 = await limiter.acquire();
    assert.equal(limiter.stats.active, 1);
    assert.equal(limiter.stats.queued, 0);

    // 1. Abort prior to acquire throws immediately
    const preAborted = new AbortController();
    preAborted.abort(new Error("Pre-aborted"));
    await assert.rejects(
      () => limiter.acquire(preAborted.signal),
      /Pre-aborted/
    );
    assert.equal(limiter.stats.active, 1);
    assert.equal(limiter.stats.queued, 0);

    // 2. Abort while waiting in queue splices out immediately
    const queuedController = new AbortController();
    const queuedPromise = limiter.acquire(queuedController.signal);
    assert.equal(limiter.stats.queued, 1);

    queuedController.abort(new Error("Cancelled while waiting in queue"));
    await assert.rejects(
      queuedPromise,
      /Cancelled while waiting in queue/
    );
    assert.equal(limiter.stats.queued, 0);
    assert.equal(limiter.stats.active, 1);

    // 3. Normal queue entry acquires when slot freed
    const normalPromise = limiter.acquire();
    assert.equal(limiter.stats.queued, 1);

    release1();
    const release2 = await normalPromise;
    assert.equal(limiter.stats.active, 1);
    assert.equal(limiter.stats.queued, 0);

    // Double release is a safe no-op
    release2();
    release2();
    assert.equal(limiter.stats.active, 0);
  });

  it("enforces renewal contract consistency where signed_url must be null for non-available items",()=>{
    // Valid available
    assert.doesNotThrow(()=>managementSalesTrackingEvidenceRenewalItemSchema.parse({
      attachment_id:"76000000-0000-4000-8000-000000000001",
      availability:"available",
      signed_url:"https://storage.example.invalid/signed/one.webp",
    }));

    // Valid non-available
    assert.doesNotThrow(()=>managementSalesTrackingEvidenceRenewalItemSchema.parse({
      attachment_id:"76000000-0000-4000-8000-000000000001",
      availability:"not_available",
      signed_url:null,
    }));
    assert.doesNotThrow(()=>managementSalesTrackingEvidenceRenewalItemSchema.parse({
      attachment_id:"76000000-0000-4000-8000-000000000001",
      availability:"signing_unavailable",
      signed_url:null,
    }));

    // Inconsistent: available but signed_url is null
    assert.throws(()=>managementSalesTrackingEvidenceRenewalItemSchema.parse({
      attachment_id:"76000000-0000-4000-8000-000000000001",
      availability:"available",
      signed_url:null,
    }),/Invalid evidence renewal availability/);

    // Inconsistent: not_available but signed_url is present
    assert.throws(()=>managementSalesTrackingEvidenceRenewalItemSchema.parse({
      attachment_id:"76000000-0000-4000-8000-000000000001",
      availability:"not_available",
      signed_url:"https://storage.example.invalid/signed/leaked.webp",
    }),/Invalid evidence renewal availability/);
  });
});
