import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
const email = process.argv[2];
if (!email || !email.includes("@"))
  throw new Error("Usage: npm run invite -- you@example.com");
const o = JSON.parse(readFileSync("cdk-outputs.json", "utf8")).Workmate;
execFileSync(
  "aws",
  [
    "cognito-idp",
    "admin-create-user",
    "--region",
    "eu-north-1",
    "--user-pool-id",
    o.UserPoolId,
    "--username",
    email,
    "--user-attributes",
    `Name=email,Value=${email}`,
    "Name=email_verified,Value=true",
    "--desired-delivery-mediums",
    "EMAIL",
  ],
  { stdio: "inherit" },
);
