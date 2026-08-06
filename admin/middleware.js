// Basic-auth gate for the whole panel. The service-role key lives ONLY in
// server code; this wall keeps the pages themselves off the open internet
// if the panel ever gets deployed. Credentials come from env — never hardcode.
import { NextResponse } from "next/server";

export function middleware(req) {
  const auth = req.headers.get("authorization") ?? "";
  const [user, pass] = auth.startsWith("Basic ")
    ? Buffer.from(auth.slice(6), "base64").toString().split(":")
    : [];
  if (user === (process.env.ADMIN_USER ?? "admin") && pass && pass === process.env.ADMIN_PASSWORD) {
    return NextResponse.next();
  }
  return new NextResponse("Auth required", {
    status: 401,
    headers: { "WWW-Authenticate": 'Basic realm="Looktok Admin"' },
  });
}

export const config = { matcher: ["/((?!_next/static|_next/image|favicon.ico).*)"] };
