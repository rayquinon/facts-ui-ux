import { createRemoteJWKSet, jwtVerify } from 'jose';

const JWKS_URL = new URL(
  'https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com',
);

const jwks = createRemoteJWKSet(JWKS_URL);

export async function verifyFirebaseIdToken(idToken, { projectId }) {
  if (!projectId) {
    throw new Error('FIREBASE_PROJECT_ID is required');
  }

  const issuer = `https://securetoken.google.com/${projectId}`;

  const { payload } = await jwtVerify(idToken, jwks, {
    issuer,
    audience: projectId,
  });

  // Payload fields: https://firebase.google.com/docs/auth/admin/verify-id-tokens
  const uid = payload.user_id;
  if (!uid || typeof uid !== 'string') {
    throw new Error('Invalid token payload: missing user_id');
  }

  return {
    uid,
    claims: payload,
  };
}
