// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Compatibility import. The smoke protocol is owned by the firmware proof;
// existing Core test runners keep this path while external firmware uses its
// copied tools directory directly.
export {
  checksum,
  createEmbeddedSwiftSmokeValidator,
  evidenceStages,
  expectedRunId,
  expectedSmokeTests,
  failureResult,
  makeRecord,
  maxDiagnosticLength,
  schemaVersion,
} from "../../../Embedded/swift/tools/validate-smoke.mjs";
