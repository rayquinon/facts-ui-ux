const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { initializeApp } = require('firebase-admin/app');
const { getAuth } = require('firebase-admin/auth');
const { getFirestore, FieldValue, FieldPath } = require('firebase-admin/firestore');

initializeApp();

function requireAdmin(request) {
  const auth = request.auth;
  if (!auth) {
    throw new HttpsError('unauthenticated', 'Authentication required.');
  }
  const email = (auth.token && auth.token.email ? String(auth.token.email) : '').toLowerCase();
  if (email !== 'admin@gmail.com') {
    throw new HttpsError('permission-denied', 'Admin privileges required.');
  }
}

async function deleteQueryInBatches(query, batchSize = 400) {
  const db = getFirestore();
  while (true) {
    const snapshot = await query.limit(batchSize).get();
    if (snapshot.empty) return 0;

    const batch = db.batch();
    for (const doc of snapshot.docs) {
      batch.delete(doc.ref);
    }
    await batch.commit();

    if (snapshot.size < batchSize) return snapshot.size;
  }
}

exports.adminApproveInstructor = onCall({ cors: true }, async (request) => {
  requireAdmin(request);
  const uid = request.data && request.data.uid ? String(request.data.uid) : '';
  if (!uid) {
    throw new HttpsError('invalid-argument', 'uid is required');
  }

  const db = getFirestore();
  await db.collection('users').doc(uid).set(
    {
      approved: true,
      approvedAt: FieldValue.serverTimestamp(),
      approvedBy: request.auth.uid,
    },
    { merge: true }
  );

  return { ok: true };
});

exports.adminClearFaceEnrollment = onCall({ cors: true }, async (request) => {
  requireAdmin(request);
  const uid = request.data && request.data.uid ? String(request.data.uid) : '';
  if (!uid) {
    throw new HttpsError('invalid-argument', 'uid is required');
  }

  const db = getFirestore();
  await db.collection('users').doc(uid).set(
    {
      faceEmbed: FieldValue.delete(),
    },
    { merge: true }
  );

  return { ok: true };
});

exports.adminDeleteUser = onCall({ cors: true, timeoutSeconds: 120 }, async (request) => {
  requireAdmin(request);
  const uid = request.data && request.data.uid ? String(request.data.uid) : '';
  if (!uid) {
    throw new HttpsError('invalid-argument', 'uid is required');
  }

  const db = getFirestore();

  // Delete per-class attendance stats for this user.
  // Stored under: classes/{classId}/attendanceStats/{studentId}
  await deleteQueryInBatches(
    db.collectionGroup('attendanceStats').where(FieldPath.documentId(), '==', uid)
  );

  // Delete per-session attendee records stored under: attendanceSessions/{sessionId}/attendees/{uid}
  await deleteQueryInBatches(
    db.collectionGroup('attendees').where(FieldPath.documentId(), '==', uid)
  );

  // Delete capture records where the user was matched.
  // Stored under: attendanceSessions/{sessionId}/captures/{captureId}
  await deleteQueryInBatches(
    db.collectionGroup('captures').where('matchUserId', '==', uid)
  );

  // Delete the user profile doc.
  try {
    await db.collection('users').doc(uid).delete();
  } catch (_) {
    // Best-effort.
  }

  // Finally, delete Firebase Auth account.
  try {
    await getAuth().deleteUser(uid);
  } catch (error) {
    throw new HttpsError('internal', `Auth deletion failed: ${error && error.message ? error.message : String(error)}`);
  }

  return { ok: true };
});
