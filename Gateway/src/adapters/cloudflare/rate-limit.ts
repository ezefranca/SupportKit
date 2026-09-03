import { sha256Hex } from "../../ServerCore/digest";

export async function edgeActorKey(request: Request): Promise<string> {
  const edgeAddress = request.headers.get("cf-connecting-ip") ?? "unknown-anonymous-client";
  return `anonymous:${await sha256Hex(edgeAddress)}`;
}

export async function verifiedActorKey(actorID: string): Promise<string> {
  return `verified:${await sha256Hex(actorID)}`;
}
