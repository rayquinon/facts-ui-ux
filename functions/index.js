const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { initializeApp } = require('firebase-admin/app');
const { getAuth } = require('firebase-admin/auth');
const { getFirestore, FieldValue, FieldPath } = require('firebase-admin/firestore');

initializeApp();

// Firebase Web API key is not a secret, but keeping it in env makes rotation easier.
// Falls back to the current project's web API key if not provided.
const FIREBASE_WEB_API_KEY =
  process.env.FIREBASE_WEB_API_KEY ||
  // facts-ui-ux (web)
  'AIzaSyCIX6BPWg4vO25X-3WuvREdArIIOU2lyK4';

function maskPhoneE164(phoneNumber) {
  if (typeof phoneNumber !== 'string' || !phoneNumber.trim()) return '';
  const digits = phoneNumber.trim().replace(/\D/g, '');
  if (digits.length <= 4) return phoneNumber.trim();
  const headLen = Math.min(3, Math.max(1, digits.length - 2));
  const head = digits.slice(0, headLen);
  const tail = digits.slice(-2);
  const stars = Math.max(0, digits.length - head.length - tail.length);
  return `+${head}${'*'.repeat(stars)}${tail}`;
}

async function verifyResetOobCode(oobCode) {
  const code = String(oobCode || '').trim();
  if (!code) {
    throw new HttpsError('invalid-argument', 'oobCode is required');
  }

  const url = `https://identitytoolkit.googleapis.com/v1/accounts:resetPassword?key=${encodeURIComponent(
    FIREBASE_WEB_API_KEY,
  )}`;

  let res;
  try {
    res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ oobCode: code }),
    });
  } catch (_) {
    throw new HttpsError('unavailable', 'Could not reach auth service');
  }

  let json;
  try {
    json = await res.json();
  } catch (_) {
    json = null;
  }

  if (!res.ok) {
    const message = json && json.error && json.error.message ? String(json.error.message) : 'INVALID_OOB_CODE';
    // Normalize common Identity Toolkit errors.
    if (message === 'EXPIRED_OOB_CODE' || message === 'INVALID_OOB_CODE') {
      throw new HttpsError('invalid-argument', 'Invalid or expired reset link');
    }
    throw new HttpsError('unknown', 'Could not validate reset link');
  }

  const email = json && typeof json.email === 'string' ? json.email.trim() : '';
  if (!email) {
    throw new HttpsError('invalid-argument', 'Invalid or expired reset link');
  }
  return { email };
}

exports.getPasswordResetPhone = onCall({ cors: true }, async (request) => {
  const oobCode = request.data && request.data.oobCode ? String(request.data.oobCode) : '';
  const { email } = await verifyResetOobCode(oobCode);

  let user;
  try {
    user = await getAuth().getUserByEmail(email);
  } catch (_) {
    // Don't leak whether the user exists; oobCode validation already ensures link possession.
    throw new HttpsError('invalid-argument', 'Invalid or expired reset link');
  }

  const phoneNumber = typeof user.phoneNumber === 'string' ? user.phoneNumber.trim() : '';
  if (!phoneNumber) {
    throw new HttpsError('failed-precondition', 'No phone number linked to this account');
  }

  return {
    ok: true,
    email,
    phoneNumber,
    maskedPhone: maskPhoneE164(phoneNumber),
  };
});

function requireSignedIn(request) {
  const auth = request.auth;
  if (!auth) {
    throw new HttpsError('unauthenticated', 'Authentication required.');
  }
  const uid = String(auth.uid || '');
  if (!uid) {
    throw new HttpsError('unauthenticated', 'Authentication required.');
  }
  return uid;
}

function isAdminClaim(request) {
  const auth = request.auth;
  return !!(
    auth &&
    auth.token &&
    (auth.token.admin === true || auth.token.admin === 'true')
  );
}

function requireAdmin(request) {
  const auth = request.auth;
  if (!auth) {
    throw new HttpsError('unauthenticated', 'Authentication required.');
  }
  // Prefer checking a custom 'admin' claim set via the Admin SDK.
  if (!isAdminClaim(request)) {
    throw new HttpsError('permission-denied', 'Admin privileges required.');
  }
}

async function hasAdminRole(uid) {
  const db = getFirestore();
  const snap = await db.collection('users').doc(uid).get();
  const role = snap.exists && snap.data() ? snap.data().role : null;
  return typeof role === 'string' && role.trim().toLowerCase() === 'admin';
}

async function getUserProfile(uid) {
  const db = getFirestore();
  const snap = await db.collection('users').doc(uid).get();
  if (!snap.exists) return null;
  const data = snap.data() || {};
  return {
    uid,
    role: typeof data.role === 'string' ? data.role.trim().toLowerCase() : null,
    approved: data.approved === true,
    displayName:
      (typeof data.displayName === 'string' && data.displayName.trim()) ||
      (typeof data['Full Name'] === 'string' && data['Full Name'].trim()) ||
      null,
    email:
      (typeof data.Email === 'string' && data.Email.trim()) ||
      (typeof data.email === 'string' && data.email.trim()) ||
      null,
    section: typeof data.section === 'string' ? data.section.trim() : '',
    studentId:
      (typeof data.studentId === 'string' && data.studentId.trim()) ||
      (typeof data['Student ID'] === 'string' && data['Student ID'].trim()) ||
      null,
  };
}

function isValidDateKey(value) {
  return typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value);
}

function parseTimeToMinutes(value) {
  if (!value) return null;
  if (typeof value === 'string') {
    const m = /^\s*(\d{1,2}):(\d{2})\s*$/.exec(value);
    if (!m) return null;
    const hh = Number(m[1]);
    const mm = Number(m[2]);
    if (!Number.isFinite(hh) || !Number.isFinite(mm)) return null;
    if (hh < 0 || hh > 23 || mm < 0 || mm > 59) return null;
    return hh * 60 + mm;
  }
  if (typeof value === 'object') {
    const hour = Number(value.hour);
    const minute = Number(value.minute);
    if (!Number.isFinite(hour) || !Number.isFinite(minute)) return null;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
    let hh = hour;
    const period = typeof value.period === 'string' ? value.period.trim().toUpperCase() : null;
    if (period === 'PM' && hh < 12) hh += 12;
    if (period === 'AM' && hh === 12) hh = 0;
    hh %= 24;
    return hh * 60 + minute;
  }
  return null;
}

function scheduleEntryToWindowMinutes(entry) {
  if (!entry || typeof entry !== 'object') return null;
  const dayRaw = entry.dayOfWeek ?? entry.day;
  let weekday = null;
  if (typeof dayRaw === 'number') {
    weekday = dayRaw;
  } else if (typeof dayRaw === 'string') {
    const v = dayRaw.trim().toLowerCase();
    const map = {
      monday: 1,
      mon: 1,
      tuesday: 2,
      tue: 2,
      wednesday: 3,
      wed: 3,
      thursday: 4,
      thu: 4,
      friday: 5,
      fri: 5,
      saturday: 6,
      sat: 6,
      sunday: 7,
      sun: 7,
    };
    weekday = map[v] ?? null;
  }
  if (!weekday || weekday < 1 || weekday > 7) return null;

  const startRaw = entry.startTime ?? entry.start;
  const endRaw = entry.endTime ?? entry.end;
  const startMin = parseTimeToMinutes(startRaw);
  const endMin = parseTimeToMinutes(endRaw);
  if (startMin == null || endMin == null) return null;
  return { weekday, startMin, endMin };
}

function weekdayFromDateKey(dateKey) {
  const [y, m, d] = dateKey.split('-').map((x) => Number(x));
  const dt = new Date(Date.UTC(y, m - 1, d));
  const jsDay = dt.getUTCDay();
  // JS: 0=Sun..6=Sat. Dart/our data: 1=Mon..7=Sun.
  return jsDay === 0 ? 7 : jsDay;
}

function windowsOverlap(aStart, aEnd, bStart, bEnd) {
  const start = Math.max(aStart, bStart);
  const end = Math.min(aEnd, bEnd);
  return end > start;
}

async function requireExcuseApprover({ request, requestDoc }) {
  const uid = requireSignedIn(request);
  if (isAdminClaim(request) || (await hasAdminRole(uid))) {
    return { uid, role: 'admin' };
  }

  const profile = await getUserProfile(uid);
  if (!profile || profile.role !== 'instructor' || profile.approved !== true) {
    throw new HttpsError('permission-denied', 'Instructor approval required.');
  }
  const data = requestDoc.data() || {};
  const instructorIds = Array.isArray(data.instructorIds) ? data.instructorIds : [];
  if (!instructorIds.includes(uid)) {
    throw new HttpsError('permission-denied', 'Not assigned to this excuse request.');
  }
  return { uid, role: 'instructor' };
}

exports.createExcuseRequest = onCall({ cors: true }, async (request) => {
  const uid = requireSignedIn(request);
  const db = getFirestore();

  const profile = await getUserProfile(uid);
  if (!profile || profile.role !== 'student') {
    throw new HttpsError('permission-denied', 'Student account required.');
  }
  if (!profile.section) {
    throw new HttpsError('failed-precondition', 'Student section is not set.');
  }

  const reason = request.data && typeof request.data.reason === 'string' ? request.data.reason.trim() : '';
  if (!reason) {
    throw new HttpsError('invalid-argument', 'reason is required');
  }
  if (reason.length > 600) {
    throw new HttpsError('invalid-argument', 'reason is too long');
  }

  const entries = request.data && Array.isArray(request.data.entries) ? request.data.entries : [];
  if (!entries.length) {
    throw new HttpsError('invalid-argument', 'entries is required');
  }

  const normalizedEntries = [];
  const dateKeys = new Set();
  for (const raw of entries) {
    if (!raw || typeof raw !== 'object') {
      throw new HttpsError('invalid-argument', 'Invalid entry');
    }
    const dateKey = String(raw.dateKey || raw.date || '').trim();
    if (!isValidDateKey(dateKey)) {
      throw new HttpsError('invalid-argument', `Invalid dateKey: ${dateKey}`);
    }
    const isFullDay = raw.isFullDay === true;
    let startMin = null;
    let endMin = null;
    if (!isFullDay) {
      startMin = parseTimeToMinutes(raw.startTime);
      endMin = parseTimeToMinutes(raw.endTime);
      if (startMin == null || endMin == null || endMin <= startMin) {
        throw new HttpsError('invalid-argument', `Invalid time range for ${dateKey}`);
      }
    }
    normalizedEntries.push({
      dateKey,
      isFullDay,
      startTime: startMin == null ? null : { minutes: startMin },
      endTime: endMin == null ? null : { minutes: endMin },
    });
    dateKeys.add(dateKey);
  }

  const classesSnap = await db.collection('classes').where('section', '==', profile.section).get();
  const instructorIds = new Set();
  for (const doc of classesSnap.docs) {
    const data = doc.data() || {};
    if (typeof data.instructorId === 'string' && data.instructorId.trim()) {
      instructorIds.add(data.instructorId.trim());
    }
  }

  const requestRef = db.collection('excuseRequests').doc();
  const storagePath = `excuseRequests/${requestRef.id}/attachment.pdf`;

  await requestRef.set({
    studentId: uid,
    studentName: profile.displayName || profile.email || uid,
    studentSection: profile.section,
    studentStudentId: profile.studentId || null,
    reason,
    entries: normalizedEntries,
    dateKeys: Array.from(dateKeys).sort(),
    instructorIds: Array.from(instructorIds),
    status: 'pending',
    attachment: null,
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  });

  return { ok: true, requestId: requestRef.id, uploadPath: storagePath };
});

exports.approveExcuseRequest = onCall({ cors: true, timeoutSeconds: 120 }, async (request) => {
  const requestId = request.data && request.data.requestId ? String(request.data.requestId) : '';
  if (!requestId) {
    throw new HttpsError('invalid-argument', 'requestId is required');
  }

  const db = getFirestore();
  const reqRef = db.collection('excuseRequests').doc(requestId);
  const reqSnap = await reqRef.get();
  if (!reqSnap.exists) {
    throw new HttpsError('not-found', 'Excuse request not found');
  }
  const approver = await requireExcuseApprover({ request, requestDoc: reqSnap });

  const reqData = reqSnap.data() || {};
  if (reqData.status === 'approved') {
    return { ok: true, alreadyApproved: true };
  }
  if (reqData.status && reqData.status !== 'pending') {
    throw new HttpsError('failed-precondition', `Cannot approve status: ${reqData.status}`);
  }

  const studentId = typeof reqData.studentId === 'string' ? reqData.studentId : '';
  const section = typeof reqData.studentSection === 'string' ? reqData.studentSection : '';
  if (!studentId || !section) {
    throw new HttpsError('failed-precondition', 'Request is missing student information');
  }
  const reason = typeof reqData.reason === 'string' ? reqData.reason : '';
  const entries = Array.isArray(reqData.entries) ? reqData.entries : [];
  if (!entries.length) {
    throw new HttpsError('failed-precondition', 'Request has no entries');
  }

  const studentProfile = await getUserProfile(studentId);
  const studentName = (studentProfile && (studentProfile.displayName || studentProfile.email)) || reqData.studentName || studentId;

  // Load classes for the student's section.
  const classesSnap = await db.collection('classes').where('section', '==', section).get();
  const classDocs = classesSnap.docs;

  const batch = db.batch();
  const now = FieldValue.serverTimestamp();

  // Mark request approved.
  batch.update(reqRef, {
    status: 'approved',
    approvedAt: now,
    approvedBy: approver.uid,
    approvedByRole: approver.role,
    updatedAt: now,
  });

  // For each class and each entry, apply overrides and update session attendee/status.
  for (const classDoc of classDocs) {
    const classId = classDoc.id;
    const classData = classDoc.data() || {};
    const schedules = Array.isArray(classData.schedules) ? classData.schedules : [];
    const scheduleWindows = schedules
      .map(scheduleEntryToWindowMinutes)
      .filter((x) => x && typeof x.weekday === 'number');

    for (const entry of entries) {
      const dateKey = typeof entry.dateKey === 'string' ? entry.dateKey : null;
      if (!dateKey || !isValidDateKey(dateKey)) continue;
      const isFullDay = entry.isFullDay === true;
      let applies = true;
      if (!isFullDay) {
        applies = false;
        const weekday = weekdayFromDateKey(dateKey);
        const startMin = entry.startTime && typeof entry.startTime.minutes === 'number' ? entry.startTime.minutes : null;
        const endMin = entry.endTime && typeof entry.endTime.minutes === 'number' ? entry.endTime.minutes : null;
        if (startMin != null && endMin != null) {
          for (const win of scheduleWindows) {
            if (win.weekday !== weekday) continue;
            if (windowsOverlap(startMin, endMin, win.startMin, win.endMin)) {
              applies = true;
              break;
            }
          }
        }
      }
      if (!applies) continue;

      // Override doc per class+student+date.
      const overrideId = `${studentId}_${dateKey}`;
      const overrideRef = db
        .collection('classes')
        .doc(classId)
        .collection('attendanceOverrides')
        .doc(overrideId);
      batch.set(
        overrideRef,
        {
          studentId,
          studentName,
          dateKey,
          status: 'excused',
          reason,
          requestId,
          approvedAt: now,
          approvedBy: approver.uid,
          createdAt: now,
        },
        { merge: true }
      );

      // Best-effort: if a session exists for that class on that date, set attendee status.
      // We use UTC day bounds based on dateKey to be stable.
      const [y, m, d] = dateKey.split('-').map((x) => Number(x));
      const dayStart = new Date(Date.UTC(y, m - 1, d, 0, 0, 0));
      const dayEnd = new Date(Date.UTC(y, m - 1, d + 1, 0, 0, 0));

      const sessionsSnap = await db
        .collection('attendanceSessions')
        .where('classId', '==', classId)
        .where('startedAt', '>=', dayStart)
        .where('startedAt', '<', dayEnd)
        .get();

      for (const sessionDoc of sessionsSnap.docs) {
        const attendeeRef = sessionDoc.ref.collection('attendees').doc(studentId);
        const attendeeSnap = await attendeeRef.get();

        let previousStatus = null;
        if (attendeeSnap.exists) {
          const attendeeData = attendeeSnap.data() || {};
          previousStatus = typeof attendeeData.status === 'string' ? attendeeData.status : null;
        } else {
          // Not captured in the session; treat as absent.
          previousStatus = 'absent';
        }

        if (previousStatus !== 'excused') {
          batch.set(
            attendeeRef,
            {
              displayName: studentName,
              status: 'excused',
              statusComputedAt: now,
              excusedByRequestId: requestId,
            },
            { merge: true }
          );

          // Update attendanceStats totals: excused counts as present.
          // Stored under: classes/{classId}/attendanceStats/{studentId}
          const statsRef = db
            .collection('classes')
            .doc(classId)
            .collection('attendanceStats')
            .doc(studentId);

          const update = {
            presentCount: FieldValue.increment(1),
            lastStatus: 'present',
            lastUpdated: now,
            lastOverrideStatus: 'excused',
          };
          if (previousStatus === 'late') {
            update.lateCount = FieldValue.increment(-1);
          } else if (previousStatus === 'absent') {
            update.absentCount = FieldValue.increment(-1);
          } else if (previousStatus === 'present') {
            // If already present, net-zero the present increment.
            update.presentCount = FieldValue.increment(0);
          }
          batch.set(statsRef, update, { merge: true });
        }
      }
    }
  }

  await batch.commit();
  return { ok: true };
});

exports.disapproveExcuseRequest = onCall({ cors: true, timeoutSeconds: 120 }, async (request) => {
  const requestId = request.data && request.data.requestId ? String(request.data.requestId) : '';
  if (!requestId) {
    throw new HttpsError('invalid-argument', 'requestId is required');
  }

  const db = getFirestore();
  const reqRef = db.collection('excuseRequests').doc(requestId);
  const reqSnap = await reqRef.get();
  if (!reqSnap.exists) {
    throw new HttpsError('not-found', 'Excuse request not found');
  }

  const approver = await requireExcuseApprover({ request, requestDoc: reqSnap });
  const reqData = reqSnap.data() || {};

  if (reqData.status === 'rejected') {
    return { ok: true, alreadyRejected: true };
  }
  if (reqData.status === 'approved') {
    throw new HttpsError('failed-precondition', 'Cannot reject an approved request');
  }
  if (reqData.status && reqData.status !== 'pending') {
    throw new HttpsError('failed-precondition', `Cannot reject status: ${reqData.status}`);
  }

  await reqRef.set(
    {
      status: 'rejected',
      rejectedAt: FieldValue.serverTimestamp(),
      rejectedBy: approver.uid,
      rejectedRole: approver.role,
      updatedAt: FieldValue.serverTimestamp(),
    },
    { merge: true },
  );

  return { ok: true };
});

exports.deleteExcuseRequest = onCall({ cors: true, timeoutSeconds: 120 }, async (request) => {
  requireAdmin(request);
  const requestId = request.data && request.data.requestId ? String(request.data.requestId) : '';
  if (!requestId) {
    throw new HttpsError('invalid-argument', 'requestId is required');
  }

  const { getStorage } = require('firebase-admin/storage');
  const db = getFirestore();
  const reqRef = db.collection('excuseRequests').doc(requestId);
  const reqSnap = await reqRef.get();

  // Delete overrides by requestId.
  try {
    const overridesSnap = await db.collectionGroup('attendanceOverrides').where('requestId', '==', requestId).get();
    let batch = db.batch();
    let count = 0;
    for (const doc of overridesSnap.docs) {
      batch.delete(doc.ref);
      count++;
      if (count % 400 === 0) {
        await batch.commit();
        batch = db.batch();
      }
    }
    if (count % 400 !== 0) {
      await batch.commit();
    }
  } catch (_) {
    // Best-effort.
  }

  // Delete attachment if we know the path, else delete the default path.
  try {
    const data = reqSnap.exists ? reqSnap.data() || {} : {};
    const attachmentPath = data.attachment && typeof data.attachment.path === 'string'
      ? data.attachment.path
      : `excuseRequests/${requestId}/attachment.pdf`;
    const bucket = getStorage().bucket();
    await bucket.file(attachmentPath).delete({ ignoreNotFound: true });
  } catch (_) {
    // Best-effort.
  }

  // Finally delete the request.
  try {
    await reqRef.delete();
  } catch (_) {
    // Best-effort.
  }

  return { ok: true };
});

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
      faceEmbeds: FieldValue.delete(),
      faceEmbedCount: FieldValue.delete(),
      faceEmbedProvider: FieldValue.delete(),
      faceEmbedUpdatedAt: FieldValue.delete(),
    },
    { merge: true }
  );

  return { ok: true };
});

exports.adminMigrateFaceEmbeds = onCall({ cors: true }, async (request) => {
  requireAdmin(request);
  const uid = request.data && request.data.uid ? String(request.data.uid) : '';
  if (!uid) {
    throw new HttpsError('invalid-argument', 'uid is required');
  }

  const db = getFirestore();
  const ref = db.collection('users').doc(uid);
  const snap = await ref.get();
  if (!snap.exists) {
    throw new HttpsError('not-found', 'User not found');
  }

  const data = snap.data() || {};
  const raw = data.faceEmbeds;
  if (!Array.isArray(raw) || raw.length === 0) {
    return { ok: true, migrated: false, reason: 'no-faceEmbeds' };
  }

  let needsMigration = false;
  const converted = [];

  for (const item of raw) {
    let rawVec = null;

    // Legacy: [num, num, ...]
    if (Array.isArray(item)) {
      needsMigration = true;
      rawVec = item;
    }

    // New: { v: [num, num, ...] }
    if (!rawVec && item && typeof item === 'object' && Array.isArray(item.v)) {
      rawVec = item.v;
    }

    if (!rawVec) continue;
    const vec = rawVec.filter((n) => typeof n === 'number' && Number.isFinite(n));
    if (vec.length) {
      converted.push({ v: vec });
    }
  }

  if (!converted.length) {
    return { ok: true, migrated: false, reason: 'no-valid-vectors' };
  }

  // If everything is already in the new shape, keep it as-is.
  if (!needsMigration) {
    const alreadyOk = raw.every(
      (x) => x && typeof x === 'object' && !Array.isArray(x) && Array.isArray(x.v)
    );
    if (alreadyOk) {
      return { ok: true, migrated: false, reason: 'already-migrated', count: converted.length };
    }
  }

  await ref.set(
    {
      faceEmbeds: converted,
      faceEmbedCount: converted.length,
      faceEmbedUpdatedAt: FieldValue.serverTimestamp(),
    },
    { merge: true }
  );

  return { ok: true, migrated: true, count: converted.length };
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

async function deleteAttendanceSessionById({ db, sessionId }) {
  const sessionRef = db.collection('attendanceSessions').doc(sessionId);
  const snap = await sessionRef.get();
  if (!snap.exists) {
    return { deleted: false, reason: 'not-found' };
  }

  // Delete known subcollections first, then delete the session doc.
  await deleteQueryInBatches(sessionRef.collection('attendees'));
  await deleteQueryInBatches(sessionRef.collection('captures'));
  await sessionRef.delete();
  return { deleted: true };
}

exports.adminDeleteAttendanceSession = onCall({ cors: true, timeoutSeconds: 300 }, async (request) => {
  requireAdmin(request);
  const sessionId = request.data && request.data.sessionId ? String(request.data.sessionId) : '';
  if (!sessionId) {
    throw new HttpsError('invalid-argument', 'sessionId is required');
  }

  const db = getFirestore();
  try {
    const res = await deleteAttendanceSessionById({ db, sessionId });
    return { ok: true, ...res };
  } catch (error) {
    throw toHttpsError('Delete attendance session', error);
  }
});

exports.adminBulkDeleteAttendanceSessions = onCall(
  { cors: true, timeoutSeconds: 540 },
  async (request) => {
    requireAdmin(request);
    const sessionIds = request.data && Array.isArray(request.data.sessionIds)
      ? request.data.sessionIds
      : null;
    if (!sessionIds || sessionIds.length === 0) {
      throw new HttpsError('invalid-argument', 'sessionIds is required');
    }
    if (sessionIds.length > 50) {
      throw new HttpsError('invalid-argument', 'Too many sessionIds (max 50 per call)');
    }

    const ids = sessionIds
      .map((x) => (typeof x === 'string' ? x.trim() : ''))
      .filter((x) => !!x);
    if (ids.length === 0) {
      throw new HttpsError('invalid-argument', 'sessionIds is empty');
    }

    const db = getFirestore();
    const deleted = [];
    const failed = [];

    for (const sessionId of ids) {
      try {
        const res = await deleteAttendanceSessionById({ db, sessionId });
        if (res.deleted) {
          deleted.push(sessionId);
        }
      } catch (error) {
        failed.push({ sessionId, error: error && error.message ? String(error.message) : String(error) });
      }
    }

    return {
      ok: true,
      requestedCount: ids.length,
      deletedCount: deleted.length,
      failedCount: failed.length,
      deletedIds: deleted,
      failed,
    };
  }
);
