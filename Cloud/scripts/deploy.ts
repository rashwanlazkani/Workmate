import { execFileSync } from "node:child_process";
import { writeFileSync, readFileSync } from "node:fs";
const profile = process.env.AWS_PROFILE || "default",
  region = "eu-north-1";
const run = (bin: string, args: string[], capture = false) =>
  execFileSync(bin, args, {
    stdio: capture ? "pipe" : "inherit",
    encoding: "utf8",
    env: { ...process.env, AWS_PROFILE: profile, AWS_REGION: region },
  });
run("npm", ["run", "build"]);
run("npm", ["run", "test"]);
const account = JSON.parse(
  run("aws", ["sts", "get-caller-identity", "--output", "json"], true),
).Account;
// CDK uses its regional bootstrap bucket for Lambda deployment assets.
try {
  run(
    "aws",
    [
      "cloudformation",
      "describe-stacks",
      "--stack-name",
      "CDKToolkit",
      "--region",
      region,
    ],
    true,
  );
} catch {
  run("npx", ["cdk", "bootstrap", `aws://${account}/${region}`]);
}
run("npx", [
  "cdk",
  "deploy",
  "Workmate",
  "--require-approval",
  "never",
  "--outputs-file",
  "cdk-outputs.json",
]);
const o = JSON.parse(readFileSync("cdk-outputs.json", "utf8")).Workmate;
const configPath = "../Resources/CloudConfig.json";
const config = JSON.parse(readFileSync(configPath, "utf8"));
writeFileSync(
  configPath,
  JSON.stringify({ ...config, region, clientId: o.ClientId, apiUrl: o.ApiUrl }, null, 2) + "\n",
);
console.log(`Workmate API deployed: ${o.ApiUrl}`);
console.log("Native app configuration updated. Rebuild from the project root: zsh Scripts/build.sh");
console.log("Provision the private iCloud config when needed: npm run provision:drive -- /path/to/Workmate/config.json");
