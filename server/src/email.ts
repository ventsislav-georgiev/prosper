import type { Bindings } from "./types";

/** Send the passwordless sign-in link via Resend. Throws on a non-2xx response. */
export async function sendMagicLinkEmail(
  env: Bindings,
  to: string,
  verifyUrl: string,
): Promise<void> {
  const html = `
  <div style="font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;max-width:480px;margin:0 auto;padding:24px;color:#1d1d1f">
    <h2 style="margin:0 0 8px">Sign in to Prosper</h2>
    <p style="margin:0 0 20px;color:#6e6e73">Click the button below to finish signing in. This link expires shortly and can be used once.</p>
    <p style="margin:0 0 24px">
      <a href="${verifyUrl}" style="display:inline-block;background:#1d1d1f;color:#fff;text-decoration:none;padding:12px 20px;border-radius:10px;font-weight:600">Sign in to Prosper</a>
    </p>
    <p style="margin:0;color:#a1a1a6;font-size:12px">If you didn't request this, you can safely ignore this email.</p>
  </div>`;

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.RESEND_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: env.EMAIL_FROM,
      to: [to],
      subject: "Your Prosper sign-in link",
      html,
    }),
  });

  if (!res.ok) {
    throw new Error(`resend_failed:${res.status}:${await res.text()}`);
  }
}
