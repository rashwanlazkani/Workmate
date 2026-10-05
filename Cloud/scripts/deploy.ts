import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
const profile = process.env.AWS_PROFILE || "default",
  region = process.env.AWS_REGION || "eu-north-1";
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
console.log(
  `Deploying Workmate to YOUR AWS account ${account}, region ${region}, profile ${profile}. AWS charges apply.`,
);
// Preserve legacy resources when upgrading an existing pre-native stack.
let legacy = false;
try {
  const stack = JSON.parse(
    run(
      "aws",
      [
        "cloudformation",
        "describe-stacks",
        "--stack-name",
        "Workmate",
        "--region",
        region,
        "--output",
        "json",
      ],
      true,
    ),
  );
  legacy =
    stack.Stacks[0].Outputs?.some(
      (o: { OutputKey: string }) => o.OutputKey === "WebsiteUrl",
    ) ?? false;
} catch (error) {
  const stderr = String((error as { stderr?: string }).stderr ?? "");
  if (!stderr.includes("does not exist")) throw error;
}
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
} catch (error) {
  if (
    !String((error as { stderr?: string }).stderr ?? "").includes(
      "does not exist",
    )
  )
    throw error;
  run("npx", ["cdk", "bootstrap", `aws://${account}/${region}`]);
}
run("npx", [
  "cdk",
  "deploy",
  "Workmate",
  "--require-approval",
  "broadening",
  "--context",
  `legacyWeb=${legacy}`,
  "--outputs-file",
  "cdk-outputs.json",
]);
const o = JSON.parse(readFileSync("cdk-outputs.json", "utf8")).Workmate;
console.log(`Workmate API deployed to your account: ${o.ApiUrl}`);
console.log("No app rebuild is needed. Connect your private workspace:");
console.log(
  "AWS_PROFILE=<your-profile> AWS_REGION=<your-region> npm run provision:drive -- /path/to/Workmate/config.json",
);
