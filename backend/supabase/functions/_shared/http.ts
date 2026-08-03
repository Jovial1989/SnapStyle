// Shared HTTP helpers for Looktok Edge Functions.
export const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...CORS, "Content-Type": "application/json" } });

export const preflight = (req: Request) =>
  req.method === "OPTIONS" ? new Response("ok", { headers: CORS }) : null;
