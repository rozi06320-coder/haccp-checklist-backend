import test from "node:test";
import assert from "node:assert/strict";
import {
  ChecklistAlreadySubmittedError,
  ChecklistConflictError,
  classifyChecklistRpcError,
} from "./checklist-persistence";

test("submitted checklist SQLSTATE is a stable terminal conflict", () => {
  assert.throws(
    () => classifyChecklistRpcError("55000", true),
    (error: unknown) => error instanceof ChecklistAlreadySubmittedError,
  );
});

test("stale revision SQLSTATE remains a reviewable conflict", () => {
  assert.throws(
    () => classifyChecklistRpcError("40001", true),
    (error: unknown) =>
      error instanceof ChecklistConflictError && error.sqlstate === "40001",
  );
});

test("55000 from non-opening mutations remains a generic conflict", () => {
  assert.throws(
    () => classifyChecklistRpcError("55000"),
    (error: unknown) => error instanceof ChecklistConflictError && error.sqlstate === "55000",
  );
});
