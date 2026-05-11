// Backfill Cloud Function to set student:true custom claim on existing imported Auth users.
// This should be appended to functions/index.js or deployed separately.
// Run via: firebase functions:shell, then adminBackfillStudentClaims()

const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { getAuth } = require('firebase-admin/auth');
const { getFirestore, FieldValue } = require('firebase-admin/firestore');

exports.adminBackfillStudentClaims = onCall(
  { cors: true, timeoutSeconds: 540 },
  async (request) => {
    const auth = getAuth();
    const db = getFirestore();

    // Verify caller is admin
    if (!request.auth) {
      throw new HttpsError('unauthenticated', 'Must be signed in');
    }

    const callerUid = request.auth.uid;
    const callerToken = request.auth.token || {};
    const isAdmin = callerToken.admin === true || callerToken.admin === 'true';

    if (!isAdmin) {
      throw new HttpsError('permission-denied', 'Must be admin to run backfill');
    }

    let processed = 0;
    let updated = 0;
    let skipped = 0;
    let failed = 0;
    const errors = [];

    try {
      // Read all user docs in the collection
      const usersSnap = await db.collection('users').get();
      console.log(`Found ${usersSnap.docs.length} docs in users collection`);

      for (const doc of usersSnap.docs) {
        try {
          processed += 1;
          const data = doc.data() || {};
          const uid = typeof data.uid === 'string' ? data.uid.trim() : '';
          const role = typeof data.role === 'string' ? data.role.trim() : '';

          // Skip if no uid or not a student
          if (!uid) {
            console.log(`Doc ${doc.id}: no uid field, skipping`);
            skipped += 1;
            continue;
          }

          if (role !== 'student') {
            console.log(`Doc ${doc.id}: role is "${role}", not student, skipping`);
            skipped += 1;
            continue;
          }

          // Get the Auth user
          let user;
          try {
            user = await auth.getUser(uid);
          } catch (getErr) {
            console.warn(`Failed to get Auth user ${uid}: ${getErr && getErr.message}`);
            failed += 1;
            errors.push({ docId: doc.id, uid, step: 'getUser', error: String(getErr && getErr.message) });
            continue;
          }

          // Check if student claim is already set
          const existingClaims = user.customClaims || {};
          if (existingClaims.student === true) {
            console.log(`Auth user ${uid}: already has student claim, skipping`);
            skipped += 1;
            continue;
          }

          // Set student claim
          try {
            const newClaims = { ...existingClaims, student: true };
            await auth.setCustomUserClaims(uid, newClaims);
            updated += 1;
            console.log(`Auth user ${uid}: set student:true claim`);
          } catch (setErr) {
            console.error(`Failed to set claim for ${uid}: ${setErr && setErr.message}`);
            failed += 1;
            errors.push({ docId: doc.id, uid, step: 'setCustomUserClaims', error: String(setErr && setErr.message) });
          }
        } catch (error) {
          failed += 1;
          console.error(`Unexpected error processing doc ${doc.id}:`, error);
          errors.push({ docId: doc.id, step: 'process', error: String(error && error.message) });
        }
      }
    } catch (error) {
      console.error('Backfill failed:', error);
      throw new HttpsError('internal', `Backfill operation failed: ${error && error.message}`);
    }

    console.log(`adminBackfillStudentClaims: processed ${processed}, updated ${updated}, skipped ${skipped}, failed ${failed}`);
    return {
      ok: true,
      processed,
      updated,
      skipped,
      failed,
      errors: errors.slice(0, 10), // Return first 10 errors for debugging
    };
  }
);
