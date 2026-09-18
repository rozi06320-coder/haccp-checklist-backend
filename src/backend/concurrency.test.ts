import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  DEFAULT_STORAGE_SIGNING_CONCURRENCY,
  MAINTENANCE_ISSUE_PHOTO_SIGNING_CONCURRENCY,
  mapWithBoundedConcurrency,
} from "./concurrency";

describe("mapWithBoundedConcurrency", () => {
  it("exports default concurrency constant of 6 and aliases maintenance constant", () => {
    assert.equal(DEFAULT_STORAGE_SIGNING_CONCURRENCY, 6);
    assert.equal(MAINTENANCE_ISSUE_PHOTO_SIGNING_CONCURRENCY, 6);
  });

  it("returns empty array immediately for empty input without invoking mapper", async () => {
    let called = 0;
    const result = await mapWithBoundedConcurrency([], 6, async () => {
      called++;
      return "test";
    });
    assert.deepEqual(result, []);
    assert.equal(called, 0);
  });

  it("executes sequentially when limit is 1", async () => {
    let active = 0;
    let maxActive = 0;
    const items = [1, 2, 3, 4, 5];
    const result = await mapWithBoundedConcurrency(items, 1, async (item) => {
      active++;
      maxActive = Math.max(maxActive, active);
      await new Promise((resolve) => setTimeout(resolve, 10));
      active--;
      return item * 2;
    });
    assert.deepEqual(result, [2, 4, 6, 8, 10]);
    assert.equal(maxActive, 1);
  });

  it("strictly bounds concurrency to limit with concurrent items finishing out of order", async () => {
    let active = 0;
    let maxActive = 0;
    const items = Array.from({ length: 20 }, (_, i) => i);
    const result = await mapWithBoundedConcurrency(items, 6, async (item) => {
      active++;
      maxActive = Math.max(maxActive, active);
      // Items complete in reverse order of item index
      const delay = (20 - item) * 2;
      await new Promise((resolve) => setTimeout(resolve, delay));
      active--;
      return `item-${item}`;
    });
    assert.ok(maxActive <= 6, `Max concurrency (${maxActive}) must not exceed 6`);
    assert.ok(maxActive > 1, `Actual concurrency (${maxActive}) must be > 1`);
    // Output must be in exact input order despite completing in reverse order
    assert.deepEqual(result, items.map((i) => `item-${i}`));
  });

  it("caps workers to items.length when limit > items.length", async () => {
    let active = 0;
    let maxActive = 0;
    const items = [1, 2, 3];
    const result = await mapWithBoundedConcurrency(items, 10, async (item) => {
      active++;
      maxActive = Math.max(maxActive, active);
      await new Promise((resolve) => setTimeout(resolve, 10));
      active--;
      return item;
    });
    assert.deepEqual(result, [1, 2, 3]);
    assert.ok(maxActive <= 3, `Max active (${maxActive}) must not exceed items.length`);
  });

  it("normalizes limit <= 0 to 1", async () => {
    let active = 0;
    let maxActive = 0;
    const items = [1, 2, 3];
    const result = await mapWithBoundedConcurrency(items, 0, async (item) => {
      active++;
      maxActive = Math.max(maxActive, active);
      await new Promise((resolve) => setTimeout(resolve, 5));
      active--;
      return item;
    });
    assert.deepEqual(result, [1, 2, 3]);
    assert.equal(maxActive, 1);
  });

  it("propagates mapper rejections cleanly to outer promise", async () => {
    const items = [1, 2, 3, 4];
    await assert.rejects(
      async () => {
        await mapWithBoundedConcurrency(items, 2, async (item) => {
          if (item === 2) throw new Error("mapper_failure");
          await new Promise((resolve) => setTimeout(resolve, 5));
          return item;
        });
      },
      { message: "mapper_failure" }
    );
  });
});
