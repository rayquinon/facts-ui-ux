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
  // Prefer checking a custom 'admin' claim set via the Admin SDK.
  const isAdmin = auth.token && (auth.token.admin === true || auth.token.admin === 'true');
  if (!isAdmin) {
    throw new HttpsError('permission-denied', 'Admin privileges required.');
  }
}

async function hasAdminRole(uid) {
  const db = getFirestore();
  const snap = await db.collection('users').doc(uid).get();
  const role = snap.exists && snap.data() ? snap.data().role : null;
  return typeof role === 'string' && role.trim().toLowerCase() === 'admin';
}

exports.bootstrapAdminClaim = onCall({ cors: true }, async (request) => {
  const auth = request.auth;
  if (!auth) {
    throw new HttpsError('unauthenticated', 'Authentication required.');
  }

  const uid = String(auth.uid || '');
  if (!uid) {
    throw new HttpsError('invalid-argument', 'uid is required');
  }

  // Bootstrap rule:
  // - You can only grant admin to yourself.
  // - Only if your Firestore profile role is explicitly 'admin'.
  // This avoids hard-coded emails while still requiring a deliberate server-side role assignment.
  const allowed = await hasAdminRole(uid);
  if (!allowed) {
    throw new HttpsError(
      'permission-denied',
      "Admin role required in Firestore (users/{uid}.role == 'admin')."
    );
  }

  const authApi = getAuth();
  const userRecord = await authApi.getUser(uid);
  const existingClaims = userRecord.customClaims || {};
  await authApi.setCustomUserClaims(uid, { ...existingClaims, admin: true });

  // Best-effort marker for troubleshooting.
  try {
    const db = getFirestore();
    await db.collection('users').doc(uid).set(
      { adminClaimSetAt: FieldValue.serverTimestamp() },
      { merge: true }
    );
  } catch (_) {
    // ignore
  }

  return { ok: true };
});

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

async function deleteSubdocForEachParent({
  parentCollectionPath,
  subcollectionName,
  subdocId,
  pageSize = 400,
}) {
  const db = getFirestore();
  let lastParentDoc = null;
  let deleted = 0;

  while (true) {
    let q = db.collection(parentCollectionPath).orderBy(FieldPath.documentId()).limit(pageSize);
    if (lastParentDoc) q = q.startAfter(lastParentDoc);

    const parentSnapshot = await q.get();
    if (parentSnapshot.empty) return deleted;

    const batch = db.batch();
    for (const parent of parentSnapshot.docs) {
      batch.delete(parent.ref.collection(subcollectionName).doc(subdocId));
      deleted += 1;
    }
    await batch.commit();

    lastParentDoc = parentSnapshot.docs[parentSnapshot.docs.length - 1];
    if (parentSnapshot.size < pageSize) return deleted;
  }
}

async function deleteCapturesMatchedUser({ uid, pageSize = 200, batchSize = 400 }) {
  const db = getFirestore();
  let lastSessionDoc = null;

  while (true) {
    let sessionQuery = db
      .collection('attendanceSessions')
      .orderBy(FieldPath.documentId())
      .limit(pageSize);
    if (lastSessionDoc) sessionQuery = sessionQuery.startAfter(lastSessionDoc);

    const sessionsSnap = await sessionQuery.get();
    if (sessionsSnap.empty) return;

    for (const sessionDoc of sessionsSnap.docs) {
      const capturesCol = sessionDoc.ref.collection('captures');
      while (true) {
        const capturesSnap = await capturesCol
          .where('matchUserId', '==', uid)
          .limit(batchSize)
          .get();
        if (capturesSnap.empty) break;

        const batch = db.batch();
        for (const cap of capturesSnap.docs) {
          batch.delete(cap.ref);
        }
        await batch.commit();

        if (capturesSnap.size < batchSize) break;
      }
    }

    lastSessionDoc = sessionsSnap.docs[sessionsSnap.docs.length - 1];
    if (sessionsSnap.size < pageSize) return;
  }
}

function toHttpsError(step, error) {
  if (error instanceof HttpsError) return error;
  const code = error && typeof error.code === 'number' ? error.code : undefined;
  const codeHint = code === 9 ? 'failed-precondition' : 'internal';
  const message = error && error.message ? String(error.message) : String(error);
  return new HttpsError(codeHint, `${step} failed: ${message}`);
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

  // NOTE: With collectionGroup queries, FieldPath.documentId() refers to the *full document path*.
  // Our uid is just a document ID segment, so we cannot query by documentId across a collectionGroup.
  // Instead, delete the known sub-document for each parent.

  // Delete per-class attendance stats for this user.
  // Stored under: classes/{classId}/attendanceStats/{uid}
  try {
    await deleteSubdocForEachParent({
      parentCollectionPath: 'classes',
      subcollectionName: 'attendanceStats',
      subdocId: uid,
    });
  } catch (error) {
    throw toHttpsError('Delete attendanceStats', error);
  }

  // Delete per-session attendee records stored under: attendanceSessions/{sessionId}/attendees/{uid}
  try {
    await deleteSubdocForEachParent({
      parentCollectionPath: 'attendanceSessions',
      subcollectionName: 'attendees',
      subdocId: uid,
    });
  } catch (error) {
    throw toHttpsError('Delete attendees', error);
  }

  // Delete capture records where the user was matched.
  // Stored under: attendanceSessions/{sessionId}/captures/{captureId}
  try {
    await deleteCapturesMatchedUser({ uid });
  } catch (error) {
    throw toHttpsError('Delete captures', error);
  }

  // Release any claimed Student ID index entries.
  try {
    await deleteQueryInBatches(db.collection('studentIdIndex').where('uid', '==', uid));
  } catch (error) {
    throw toHttpsError('Delete studentIdIndex', error);
  }

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
