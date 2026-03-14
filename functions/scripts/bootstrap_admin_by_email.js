#!/usr/bin/env node
/**
 * One-time admin bootstrap.
 *
 * What it does:
 * - Finds a Firebase Auth user by email
 * - Sets custom claim: { admin: true }
 * - Ensures Firestore /users/{uid} has role="admin"
 *
 * Prereqs:
 * - Provide credentials via Application Default Credentials (ADC)
 *   e.g. set GOOGLE_APPLICATION_CREDENTIALS to a service account json.
 *
 * Usage:
 *   node scripts/bootstrap_admin_by_email.js factsapp2025@gmail.com
 *   node scripts/bootstrap_admin_by_email.js factsapp2025@gmail.com --mark-verified
 */

const { initializeApp, applicationDefault } = require('firebase-admin/app');
const { getAuth } = require('firebase-admin/auth');
const { getFirestore, FieldValue } = require('firebase-admin/firestore');

async function main() {
  const email = String(process.argv[2] || '').trim();
  if (!email) {
    throw new Error(
      'Usage: node scripts/bootstrap_admin_by_email.js <email> [--mark-verified]',
    );
  }

  const markVerified = process.argv.includes('--mark-verified');

  // If ADC is configured, applicationDefault() will pick it up.
  initializeApp({ credential: applicationDefault() });

  const auth = getAuth();
  const db = getFirestore();

  const user = await auth.getUserByEmail(email);

  if (markVerified && user.emailVerified !== true) {
    await auth.updateUser(user.uid, { emailVerified: true });
  }

  // Set custom claim for VPS + Cloud Functions admin gating.
  const existingClaims = user.customClaims || {};
  const nextClaims = { ...existingClaims, admin: true };
  await auth.setCustomUserClaims(user.uid, nextClaims);

  // Ensure Firestore user profile reflects admin role (used by UI).
  await db
    .collection('users')
    .doc(user.uid)
    .set(
      {
        role: 'admin',
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

  const refreshed = await auth.getUser(user.uid);
  console.log(
    JSON.stringify({
      ok: true,
      uid: refreshed.uid,
      email: refreshed.email,
      emailVerified: refreshed.emailVerified,
      claims: nextClaims,
    }),
  );
  console.log('NOTE: The user must sign out/in to refresh their ID token claims.');
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
