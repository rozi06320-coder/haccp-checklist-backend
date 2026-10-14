import path from "node:path";
import { validateBaladiyahPhotoAssets } from "../src/lib/training/baladiyah-photo-asset-validator.js";

const args = process.argv.slice(2);
const strict = args.includes("--strict");
const publicRootArgument = args.find((argument) => argument.startsWith("--public-root="));
const publicRoot = path.resolve(publicRootArgument?.slice("--public-root=".length) || path.join(process.cwd(), "public"));
const result = validateBaladiyahPhotoAssets({ publicRoot, strict });

console.log(`Baladiyah photo assets: ${result.mode} mode`);
console.log(`Manifest: ${result.asset_count} assets; approved: ${result.approved_count}; missing files: ${result.missing_file_count}`);

for (const issue of result.issues) {
  console.log(`${issue.severity.toUpperCase()} ${issue.code}${issue.asset_key ? ` [${issue.asset_key}]` : ""}: ${issue.message}`);
}

if (result.valid) {
  console.log(strict ? "Strict asset validation passed." : "Draft asset structure is valid; pending assets are reported as warnings.");
} else {
  console.error("Baladiyah photo asset validation failed.");
  process.exitCode = 1;
}
