import type {
  APIGatewayProxyEventV2WithJWTAuthorizer,
  APIGatewayProxyResultV2,
} from "aws-lambda";
import { agentIdentity, agentRoute } from "./agent";
import { deviceIdentity, deviceRoute } from "./device";
import { timingSafeEqual } from "node:crypto";
import { Conflict, DynamoRepository, SecretVault } from "./repository";
import { Service, type TelegramUpdate } from "./service";
const service = new Service(
  new DynamoRepository(),
  new SecretVault(),
  "cloud",
  process.env.WEBHOOK_SECRET,
);
const response = (
  statusCode: number,
  data: unknown,
): APIGatewayProxyResultV2 => ({
  statusCode,
  headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  body: JSON.stringify(data),
});
export async function handler(
  event: APIGatewayProxyEventV2WithJWTAuthorizer,
): Promise<APIGatewayProxyResultV2> {
  try {
    const isAgent = event.rawPath.startsWith("/agent/");
    const isDevice = event.rawPath.startsWith("/device/");
    const path = event.rawPath.replace(isAgent ? /^\/agent/ : isDevice ? /^\/device/ : /^\/api/, "");
    if (Buffer.byteLength(event.body || "") > 4200000)
      return response(413, { error: "Request too large" });
    const data = event.body
      ? JSON.parse(
          event.isBase64Encoded
            ? Buffer.from(event.body, "base64").toString()
            : event.body,
        )
      : {};
    if (!isAgent && !isDevice && path.startsWith("/telegram/webhook/")) {
      const actual = Buffer.from(
          event.headers["x-telegram-bot-api-secret-token"] || "",
        ),
        expected = Buffer.from(process.env.WEBHOOK_SECRET || "");
      if (
        !expected.length ||
        actual.length !== expected.length ||
        !timingSafeEqual(actual, expected)
      )
        return response(403, { error: "Forbidden" });
      const hash = path.split("/").pop()!;
      if (!/^[a-f0-9]{32}$/.test(hash))
        return response(400, { error: "Invalid route" });
      await service.incoming(hash, data as TelegramUpdate);
      return response(200, { ok: true });
    }
    if (isAgent) {
      const owner = await agentIdentity(service.repo, event.headers.authorization);
      if (!owner) return response(401, { error: "Invalid reminder agent key." });
      return response(200, await agentRoute(service, owner, event.requestContext.http.method, path, data));
    }
    if (isDevice) {
      const owner = await deviceIdentity(service.repo, event.headers.authorization);
      if (!owner) return response(401, { error: "Invalid workspace connection key." });
      return response(200, await deviceRoute(service, owner, event.requestContext.http.method, path, data, `https://${event.requestContext.domainName}`));
    }
    const user = event.requestContext.authorizer?.jwt?.claims?.sub;
    if (typeof user !== "string")
      return response(401, { error: "Sign in to access your workspace." });
    return response(
      200,
      await service.route(
        user,
        event.requestContext.http.method,
        path,
        data,
        `https://${event.requestContext.domainName}`,
      ),
    );
  } catch (e) {
    const err = e as Error & { status?: number };
    const validation = err.name === "ZodError" || err.name === "SyntaxError";
    if (event.rawPath.includes("/webhook/")) {
      console.error("Telegram webhook processing failed", { type: err.name });
      return response(500, { error: "Delivery failed" });
    }
    if (err instanceof Conflict) return response(409, { error: err.message });
    if (validation)
      return response(400, {
        error: "Invalid request. Check field lengths and dates.",
      });
    if (err.status) return response(err.status, { error: err.message });
    if (
      err.message.startsWith("Telegram:") ||
      err.message.startsWith("Connect your") ||
      err.message.startsWith("Workspace is")
    )
      return response(400, { error: err.message });
    console.error("API request failed", { type: err.name });
    return response(500, {
      error:
        "Could not save this change. Your edits are still in this window. Please retry.",
    });
  }
}
