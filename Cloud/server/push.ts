import { IoTDataPlaneClient, PublishCommand } from "@aws-sdk/client-iot-data-plane";
import { userHash } from "./service";

export const changeTopic = (user: string) => `workmate/${userHash(user)}/changes`;

export async function publishScheduleChange(user: string, revision: number) {
  if (!process.env.IOT_DATA_ENDPOINT) return;
  const client = new IoTDataPlaneClient({ endpoint: `https://${process.env.IOT_DATA_ENDPOINT}` });
  await client.send(new PublishCommand({
    topic: changeTopic(user), qos: 1,
    payload: Buffer.from(JSON.stringify({ kind: "schedule.changed", revision })),
  }));
}
