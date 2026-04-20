const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { onDocumentCreated, onDocumentWritten } = require('firebase-functions/v2/firestore');
const { onSchedule } = require('firebase-functions/v2/scheduler');
const { initializeApp } = require('firebase-admin/app');
const { getAuth } = require('firebase-admin/auth');
const { getMessaging } = require('firebase-admin/messaging');
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

function clampInt(value, fallback = 0) {
  const n = Number(value);
  return Number.isFinite(n) ? Math.trunc(n) : fallback;
}

function normalizeTopicPart(raw) {
  return String(raw || '')
    .trim()
    .toLowerCase()
    .replace(/\s+/g, '_')
    .replace(/[^a-z0-9_\-]/g, '');
}

function userTopic(uid) {
  return `user_${normalizeTopicPart(uid)}`;
}

function sectionTopic(section) {
  return `section_${normalizeTopicPart(section)}`;
}

function manilaNowParts(now = new Date()) {
  const fmt = new Intl.DateTimeFormat('en-US', {
    timeZone: 'Asia/Manila',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    weekday: 'short',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  });
  const parts = fmt.formatToParts(now);
  const get = (type) => parts.find((p) => p.type === type)?.value;
  const year = clampInt(get('year'));
  const month = clampInt(get('month'));
  const day = clampInt(get('day'));
  const hour = clampInt(get('hour'));
  const minute = clampInt(get('minute'));
  const weekdayShort = String(get('weekday') || '').toLowerCase();
  const weekdayMap = {
    mon: 1,
    tue: 2,
    wed: 3,
    thu: 4,
    fri: 5,
    sat: 6,
    sun: 7,
  };
  const weekday = weekdayMap[weekdayShort] ?? null;
  const dateKey = `${String(year).padStart(4, '0')}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
  return { dateKey, weekday, minutesOfDay: hour * 60 + minute };
}

function attendanceSessionDurationMinutes(sessionData) {
  const startHour = clampInt(sessionData.startHour, 0);
  const startMinute = clampInt(sessionData.startMinute, 0);
  const endHour = clampInt(sessionData.endHour, 0);
  const endMinute = clampInt(sessionData.endMinute, 0);
  let start = startHour * 60 + startMinute;
  let end = endHour * 60 + endMinute;
  if (end <= start) end += 24 * 60;
  const dur = end - start;
  return dur > 0 ? dur : 0;
}

async function createUserNotification({ uid, type, title, body, data }) {
  const db = getFirestore();
  const ref = db.collection('users').doc(uid).collection('notifications').doc();
  await ref.set({
    type: String(type || 'generic'),
    title: String(title || 'Notification'),
    body: String(body || ''),
    data: data && typeof data === 'object' ? data : {},
    createdAt: FieldValue.serverTimestamp(),
    readAt: null,
  });
  return ref.id;
}

async function pushToTopic({ topic, title, body, data }) {
  if (!topic) return;
  const payload = {
    topic,
    notification: {
      title: String(title || 'FACTS'),
      body: String(body || ''),
    },
    data: Object.fromEntries(
      Object.entries(data && typeof data === 'object' ? data : {}).map(([k, v]) => [k, String(v)])
    ),
    android: {
      priority: 'high',
    },
  };
  try {
    await getMessaging().send(payload);
  } catch (e) {
    // Best-effort.
    console.warn('pushToTopic failed', e);
  }
}

async function notifyUser({ uid, type, title, body, data }) {
  await createUserNotification({ uid, type, title, body, data });
  await pushToTopic({ topic: userTopic(uid), title, body, data: { type, ...(data || {}) } });
}

async function notifySection({ section, title, body, data }) {
  await pushToTopic({ topic: sectionTopic(section), title, body, data });
}

async function listStudentsInSection(section) {
  const db = getFirestore();
  const snap = await db
    .collection('users')
    .where('role', '==', 'student')
    .where('section', '==', section)
    .get();
  return snap.docs.map((d) => d.id);
}

async function fanoutInAppNotifications({ uids, type, title, body, data }) {
  const db = getFirestore();
  const now = FieldValue.serverTimestamp();
  const chunks = [];
  for (let i = 0; i < uids.length; i += 450) chunks.push(uids.slice(i, i + 450));
  for (const chunk of chunks) {
    const batch = db.batch();
    for (const uid of chunk) {
      const ref = db.collection('users').doc(uid).collection('notifications').doc();
      batch.set(ref, {
        type: String(type || 'generic'),
        title: String(title || 'Notification'),
        body: String(body || ''),
        data: data && typeof data === 'object' ? data : {},
        createdAt: now,
        readAt: null,
      });
    }
    await batch.commit();
  }
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
        const sessionData = sessionDoc.data() || {};
        const sessionMinutes = attendanceSessionDurationMinutes(sessionData);
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
            if (sessionMinutes > 0) {
              update.absentMinutes = FieldValue.increment(-sessionMinutes);
            }
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

  // Best-effort: notify student that their request was approved.
  try {
    await notifyUser({
      uid: studentId,
      type: 'excuse_approved',
      title: 'Excuse request approved',
      body: 'Your excuse request was approved.',
      data: { requestId },
    });
  } catch (_) {
    // Best-effort.
  }

  return { ok: true };
});

exports.onExcuseRequestCreated = onDocumentCreated('excuseRequests/{requestId}', async (event) => {
  const snap = event.data;
  if (!snap) return;
  const data = snap.data() || {};
  const instructorIds = Array.isArray(data.instructorIds) ? data.instructorIds.filter((x) => typeof x === 'string' && x.trim()) : [];
  if (!instructorIds.length) return;
  const studentName = typeof data.studentName === 'string' ? data.studentName : 'A student';
  const section = typeof data.studentSection === 'string' ? data.studentSection : '';
  const title = 'New excuse request';
  const body = section ? `${studentName} submitted an excuse request (Section ${section}).` : `${studentName} submitted an excuse request.`;

  // In-app + push per instructor.
  await Promise.all(
    instructorIds.map((uid) =>
      notifyUser({
        uid,
        type: 'excuse_submitted',
        title,
        body,
        data: { requestId: snap.id, studentId: String(data.studentId || ''), section },
      })
    )
  );
});

exports.onAttendanceStatsWritten = onDocumentWritten('classes/{classId}/attendanceStats/{studentId}', async (event) => {
  const after = event.data.after;
  if (!after || !after.exists) return;

  const classId = event.params.classId;
  const studentId = event.params.studentId;
  const afterData = after.data() || {};
  const absentMinutes = clampInt(afterData.absentMinutes, 0);

  const crossed10 = absentMinutes >= 10 * 60;
  const crossed15 = absentMinutes >= 15 * 60;

  const db = getFirestore();
  const statsRef = db.collection('classes').doc(classId).collection('attendanceStats').doc(studentId);

  // Load class meta for messages.
  const classSnap = await db.collection('classes').doc(classId).get();
  const classData = classSnap.exists ? classSnap.data() || {} : {};
  const subjectCode = typeof classData.subjectCode === 'string' ? classData.subjectCode : 'Class';
  const instructorId = typeof classData.instructorId === 'string' ? classData.instructorId : null;

  async function handleThreshold({ minutes, field, label }) {
    await db.runTransaction(async (tx) => {
      const fresh = await tx.get(statsRef);
      if (!fresh.exists) return;
      const d = fresh.data() || {};
      const currentMinutes = clampInt(d.absentMinutes, 0);
      if (currentMinutes < minutes) return;
      if (d[field]) return;
      tx.set(statsRef, { [field]: FieldValue.serverTimestamp() }, { merge: true });
    });

    // Re-read quickly to ensure we only notify once (transaction wrote field).
    const confirm = await statsRef.get();
    const confirmData = confirm.exists ? confirm.data() || {} : {};
    if (!confirmData[field]) return;

    const hours = Math.floor(absentMinutes / 60);
    const mins = absentMinutes % 60;
    const human = mins ? `${hours}h ${mins}m` : `${hours}h`;
    const title = 'Absence warning';
    const body = `${subjectCode}: total absences reached ${human} (${label}).`;
    await notifyUser({
      uid: studentId,
      type: 'absence_threshold',
      title,
      body,
      data: { classId, thresholdMinutes: minutes, absentMinutes },
    });
    if (instructorId) {
      await notifyUser({
        uid: instructorId,
        type: 'student_absence_threshold',
        title: 'Student absence warning',
        body: `${subjectCode}: a student reached ${human} absences (${label}).`,
        data: { classId, studentId, thresholdMinutes: minutes, absentMinutes },
      });
    }
  }

  // Avoid doing extra work if nothing is crossed.
  if (!crossed10 && !crossed15) return;

  if (crossed10) {
    await handleThreshold({ minutes: 10 * 60, field: 'absenceNotified10hAt', label: '10 hours' });
  }
  if (crossed15) {
    await handleThreshold({ minutes: 15 * 60, field: 'absenceNotified15hAt', label: '15 hours' });
  }
});

exports.onAttendanceSessionAttendeeWritten = onDocumentWritten(
  'attendanceSessions/{sessionId}/attendees/{studentId}',
  async (event) => {
    const after = event.data.after;
    if (!after || !after.exists) return;

    const before = event.data.before;
    const afterData = after.data() || {};
    const beforeData = before && before.exists ? before.data() || {} : {};

    const statusAfter = typeof afterData.status === 'string' ? afterData.status.trim().toLowerCase() : '';
    const statusBefore = typeof beforeData.status === 'string' ? beforeData.status.trim().toLowerCase() : '';

    const minutesLateAfter = clampInt(afterData.minutesLate, 0);
    const minutesLateBefore = clampInt(beforeData.minutesLate, 0);
    const minutesAbsentAfter = clampInt(afterData.minutesAbsent, 0);
    const minutesAbsentBefore = clampInt(beforeData.minutesAbsent, 0);

    // Fast no-op: ignore noisy updates (confidence/lastCapturedAt/etc.).
    if (
      statusAfter === statusBefore &&
      minutesLateAfter === minutesLateBefore &&
      minutesAbsentAfter === minutesAbsentBefore
    ) {
      return;
    }

    const db = getFirestore();
    const sessionId = event.params.sessionId;
    const studentId = event.params.studentId;

    const sessionSnap = await db.collection('attendanceSessions').doc(sessionId).get();
    if (!sessionSnap.exists) return;
    const session = sessionSnap.data() || {};

    const classId = typeof session.classId === 'string' ? session.classId.trim() : '';
    if (!classId) return;

    const dateKeyRaw =
      (typeof session.effectiveDateKey === 'string' && session.effectiveDateKey.trim())
        ? session.effectiveDateKey.trim()
        : (typeof session.dateKey === 'string' ? session.dateKey.trim() : '');
    const dateKey = isValidDateKey(dateKeyRaw) ? dateKeyRaw : null;
    if (!dateKey) return;

    function metrics(status, minutesLate, minutesAbsent) {
      const s = typeof status === 'string' ? status : '';
      if (s === 'present') {
        return { presentCount: 1, lateCount: 0, absentCount: 0, lateMinutes: 0, absentMinutes: 0 };
      }
      if (s === 'late') {
        return { presentCount: 0, lateCount: 1, absentCount: 0, lateMinutes: clampInt(minutesLate, 0), absentMinutes: 0 };
      }
      if (s === 'absent') {
        return { presentCount: 0, lateCount: 0, absentCount: 1, lateMinutes: 0, absentMinutes: clampInt(minutesAbsent, 0) };
      }
      return { presentCount: 0, lateCount: 0, absentCount: 0, lateMinutes: 0, absentMinutes: 0 };
    }

    const afterM = metrics(statusAfter, minutesLateAfter, minutesAbsentAfter);
    const beforeM = metrics(statusBefore, minutesLateBefore, minutesAbsentBefore);

    const delta = {
      presentCount: afterM.presentCount - beforeM.presentCount,
      lateCount: afterM.lateCount - beforeM.lateCount,
      absentCount: afterM.absentCount - beforeM.absentCount,
      lateMinutes: afterM.lateMinutes - beforeM.lateMinutes,
      absentMinutes: afterM.absentMinutes - beforeM.absentMinutes,
    };

    const hasDelta = Object.values(delta).some((v) => v !== 0);
    if (!hasDelta) return;

    const dailyRef = db
      .collection('classes')
      .doc(classId)
      .collection('students')
      .doc(studentId)
      .collection('daily')
      .doc(dateKey);

    const update = {
      classId,
      studentId,
      dateKey,
      updatedAt: FieldValue.serverTimestamp(),
    };

    if (delta.presentCount) update.presentCount = FieldValue.increment(delta.presentCount);
    if (delta.lateCount) update.lateCount = FieldValue.increment(delta.lateCount);
    if (delta.absentCount) update.absentCount = FieldValue.increment(delta.absentCount);
    if (delta.lateMinutes) update.lateMinutes = FieldValue.increment(delta.lateMinutes);
    if (delta.absentMinutes) update.absentMinutes = FieldValue.increment(delta.absentMinutes);

    await dailyRef.set(update, { merge: true });
  }
);

exports.sendNextClassReminders = onSchedule(
  {
    schedule: 'every 5 minutes',
    timeZone: 'Asia/Manila',
  },
  async () => {
    const db = getFirestore();
    const { dateKey, weekday, minutesOfDay } = manilaNowParts();
    if (!weekday || !isValidDateKey(dateKey)) return;

    const target = minutesOfDay + 30;
    const windowStart = target;
    const windowEnd = target + 4; // runs every 5 minutes

    const classesSnap = await db.collection('classes').get();
    if (classesSnap.empty) return;

    for (const classDoc of classesSnap.docs) {
      const classData = classDoc.data() || {};
      const section = typeof classData.section === 'string' ? classData.section : '';
      const instructorId = typeof classData.instructorId === 'string' ? classData.instructorId : null;
      const subjectCode = typeof classData.subjectCode === 'string' ? classData.subjectCode : 'Class';
      const subjectName = typeof classData.subjectName === 'string' ? classData.subjectName : '';
      const schedules = Array.isArray(classData.schedules) ? classData.schedules : [];

      for (const raw of schedules) {
        const win = scheduleEntryToWindowMinutes(raw);
        if (!win) continue;
        if (win.weekday !== weekday) continue;
        if (win.startMin < windowStart || win.startMin > windowEnd) continue;

        const dedupeId = `reminder_${classDoc.id}_${dateKey}_${win.startMin}`;
        const dedupeRef = db.collection('notificationDedupes').doc(dedupeId);
        const created = await db.runTransaction(async (tx) => {
          const snap = await tx.get(dedupeRef);
          if (snap.exists) return false;
          tx.set(dedupeRef, { createdAt: FieldValue.serverTimestamp(), classId: classDoc.id, dateKey, startMin: win.startMin });
          return true;
        });
        if (!created) continue;

        const startH = Math.floor(win.startMin / 60);
        const startM = String(win.startMin % 60).padStart(2, '0');
        const title = 'Class starting soon';
        const subtitle = subjectName ? `${subjectCode} • ${subjectName}` : subjectCode;
        const body = `${subtitle} starts at ${startH}:${startM}.`;

        // Push to all students in the section.
        if (section) {
          await notifySection({
            section,
            title,
            body,
            data: { type: 'next_class', classId: classDoc.id, section, dateKey, startMin: win.startMin },
          });
        }

        // In-app fanout for students.
        if (section) {
          try {
            const studentUids = await listStudentsInSection(section);
            if (studentUids.length) {
              await fanoutInAppNotifications({
                uids: studentUids,
                type: 'next_class',
                title,
                body,
                data: { classId: classDoc.id, section, dateKey, startMin: win.startMin },
              });
            }
          } catch (e) {
            console.warn('fanout students failed', e);
          }
        }

        // Instructor: in-app + push.
        if (instructorId) {
          await notifyUser({
            uid: instructorId,
            type: 'next_class',
            title,
            body,
            data: { classId: classDoc.id, section, dateKey, startMin: win.startMin },
          });
        }
      }
    }
  }
);

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

  // VPS embeddings API authorizes roster reads using Firebase custom claims.
  // Ensure approved instructors receive an `instructor: true` claim.
  try {
    const authApi = getAuth();
    const userRecord = await authApi.getUser(uid);
    const existingClaims = userRecord.customClaims || {};
    await authApi.setCustomUserClaims(uid, { ...existingClaims, instructor: true });

    // Best-effort marker for troubleshooting.
    await db.collection('users').doc(uid).set(
      { instructorClaimSetAt: FieldValue.serverTimestamp() },
      { merge: true }
    );
  } catch (_) {
    // Best-effort. Approval should still succeed even if claims update fails.
  }

  return { ok: true };
});

exports.bootstrapInstructorClaim = onCall({ cors: true }, async (request) => {
  const uid = requireSignedIn(request);

  const profile = await getUserProfile(uid);
  if (!profile) {
    throw new HttpsError('failed-precondition', 'User profile not found.');
  }

  if (profile.role !== 'instructor') {
    throw new HttpsError('permission-denied', 'Instructor role required.');
  }
  if (profile.approved !== true) {
    throw new HttpsError('permission-denied', 'Instructor account is not approved yet.');
  }

  const authApi = getAuth();
  const userRecord = await authApi.getUser(uid);
  const existingClaims = userRecord.customClaims || {};

  // Only grant to self.
  await authApi.setCustomUserClaims(uid, { ...existingClaims, instructor: true });

  // Best-effort marker for troubleshooting.
  try {
    const db = getFirestore();
    await db.collection('users').doc(uid).set(
      { instructorClaimSetAt: FieldValue.serverTimestamp() },
      { merge: true }
    );
  } catch (_) {
    // ignore
  }

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

function normalizeStatus(raw) {
  return typeof raw === 'string' ? raw.trim().toLowerCase() : '';
}

function safeDateKeyFromSession(session) {
  const raw =
    (typeof session.effectiveDateKey === 'string' && session.effectiveDateKey.trim())
      ? session.effectiveDateKey.trim()
      : (typeof session.dateKey === 'string' ? session.dateKey.trim() : '');
  return isValidDateKey(raw) ? raw : null;
}

function clampDown(value) {
  return Math.max(0, clampInt(value, 0));
}

function decrementDocFields({ current, status, minutesLate, minutesAbsent, legacy = false }) {
  const updates = {};

  const presentKey = legacy ? 'present' : 'presentCount';
  const lateKey = legacy ? 'late' : 'lateCount';
  const absentKey = legacy ? 'absent' : 'absentCount';

  if (status === 'present') {
    if (presentKey in current) {
      updates[presentKey] = Math.max(0, clampInt(current[presentKey], 0) - 1);
    }
  } else if (status === 'late') {
    if (lateKey in current) {
      updates[lateKey] = Math.max(0, clampInt(current[lateKey], 0) - 1);
    }
    if ('lateMinutes' in current) {
      updates.lateMinutes = Math.max(0, clampInt(current.lateMinutes, 0) - clampInt(minutesLate, 0));
    }
  } else if (status === 'absent') {
    if (absentKey in current) {
      updates[absentKey] = Math.max(0, clampInt(current[absentKey], 0) - 1);
    }
    if ('absentMinutes' in current) {
      updates.absentMinutes = Math.max(0, clampInt(current.absentMinutes, 0) - clampInt(minutesAbsent, 0));
    }
  }

  return updates;
}

async function rollbackAttendanceDerivedDataForSession({ db, sessionId }) {
  const sessionRef = db.collection('attendanceSessions').doc(sessionId);
  const sessionSnap = await sessionRef.get();
  if (!sessionSnap.exists) {
    return { ok: true, rolledBack: false, reason: 'not-found' };
  }
  const session = sessionSnap.data() || {};
  const classId = typeof session.classId === 'string' ? session.classId.trim() : '';
  if (!classId) {
    return { ok: true, rolledBack: false, reason: 'missing-classId' };
  }

  const dateKey = safeDateKeyFromSession(session);
  if (!dateKey) {
    return { ok: true, rolledBack: false, reason: 'missing-dateKey' };
  }

  const attendeesSnap = await sessionRef.collection('attendees').get();
  if (attendeesSnap.empty) {
    return { ok: true, rolledBack: false, reason: 'no-attendees' };
  }

  let touchedStats = 0;
  let touchedDaily = 0;

  for (const doc of attendeesSnap.docs) {
    const studentId = doc.id;
    const data = doc.data() || {};
    const status = normalizeStatus(data.status);
    if (status !== 'present' && status !== 'late' && status !== 'absent') {
      continue;
    }
    const minutesLate = clampInt(data.minutesLate, 0);
    const minutesAbsent = clampInt(data.minutesAbsent, 0);

    // Roll back totals stored under: classes/{classId}/attendanceStats/{studentId}
    const statsRef = db.collection('classes').doc(classId).collection('attendanceStats').doc(studentId);
    const statsSnap = await statsRef.get();
    if (statsSnap.exists) {
      const current = statsSnap.data() || {};

      // Support both legacy (present/late/absent) and current (*Count) schemas.
      const updates = {
        ...decrementDocFields({ current, status, minutesLate, minutesAbsent, legacy: false }),
        ...decrementDocFields({ current, status, minutesLate, minutesAbsent, legacy: true }),
      };

      if (Object.keys(updates).length) {
        await statsRef.set(updates, { merge: true });
        touchedStats += 1;
      }
    }

    // Roll back per-day rollups stored under: classes/{classId}/students/{studentId}/daily/{dateKey}
    const dailyRef = db
      .collection('classes')
      .doc(classId)
      .collection('students')
      .doc(studentId)
      .collection('daily')
      .doc(dateKey);
    const dailySnap = await dailyRef.get();
    if (dailySnap.exists) {
      const current = dailySnap.data() || {};
      const updates = decrementDocFields({ current, status, minutesLate, minutesAbsent, legacy: false });
      if (Object.keys(updates).length) {
        await dailyRef.set({ ...updates, updatedAt: FieldValue.serverTimestamp() }, { merge: true });
        touchedDaily += 1;
      }
    }
  }

  return { ok: true, rolledBack: true, classId, dateKey, touchedStats, touchedDaily };
}

exports.adminDeleteAttendanceSession = onCall({ cors: true, timeoutSeconds: 300 }, async (request) => {
  requireAdmin(request);
  const sessionId = request.data && request.data.sessionId ? String(request.data.sessionId) : '';
  if (!sessionId) {
    throw new HttpsError('invalid-argument', 'sessionId is required');
  }

  const db = getFirestore();
  try {
    // Ensure derived aggregates are rolled back so students don't keep
    // showing present/late/absent after deleting a session.
    const rollback = await rollbackAttendanceDerivedDataForSession({ db, sessionId });
    const res = await deleteAttendanceSessionById({ db, sessionId });
    return { ok: true, ...res, rollback };
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

exports.mergeAttendanceSessionAttemptsForSlot = onCall(
  { cors: true, timeoutSeconds: 540 },
  async (request) => {
    const uid = requireSignedIn(request);
    const canonicalSessionId = request.data && request.data.canonicalSessionId
      ? String(request.data.canonicalSessionId).trim()
      : '';
    const sessionIdsRaw = request.data && Array.isArray(request.data.sessionIds)
      ? request.data.sessionIds
      : null;

    if (!canonicalSessionId) {
      throw new HttpsError('invalid-argument', 'canonicalSessionId is required');
    }
    if (!sessionIdsRaw || sessionIdsRaw.length === 0) {
      throw new HttpsError('invalid-argument', 'sessionIds is required');
    }
    if (sessionIdsRaw.length > 50) {
      throw new HttpsError('invalid-argument', 'Too many sessionIds (max 50 per call)');
    }

    const sessionIds = sessionIdsRaw
      .map((x) => (typeof x === 'string' ? x.trim() : ''))
      .filter((x) => !!x);
    if (sessionIds.length === 0) {
      throw new HttpsError('invalid-argument', 'sessionIds is empty');
    }
    if (!sessionIds.includes(canonicalSessionId)) {
      sessionIds.push(canonicalSessionId);
    }

    const db = getFirestore();

    const canonicalRef = db.collection('attendanceSessions').doc(canonicalSessionId);
    const canonicalSnap = await canonicalRef.get();
    if (!canonicalSnap.exists) {
      throw new HttpsError('failed-precondition', 'Canonical session not found');
    }
    const canonicalData = canonicalSnap.data() || {};
    const canonicalInstructorId = typeof canonicalData.instructorId === 'string' ? canonicalData.instructorId.trim() : '';
    const canonicalClassId = typeof canonicalData.classId === 'string' ? canonicalData.classId.trim() : '';

    const isAdmin = isAdminClaim(request);
    if (!isAdmin) {
      if (!canonicalInstructorId || canonicalInstructorId !== uid) {
        throw new HttpsError('permission-denied', 'Only the session instructor can merge attempts');
      }
    }

    async function mergeAttendeesFromSession(sessionId) {
      const ref = db.collection('attendanceSessions').doc(sessionId);
      const snap = await ref.get();
      if (!snap.exists) return { merged: 0, skipped: true };

      const data = snap.data() || {};
      const instructorId = typeof data.instructorId === 'string' ? data.instructorId.trim() : '';
      const classId = typeof data.classId === 'string' ? data.classId.trim() : '';
      if (canonicalInstructorId && instructorId && canonicalInstructorId !== instructorId) {
        return { merged: 0, skipped: true };
      }
      if (canonicalClassId && classId && canonicalClassId !== classId) {
        return { merged: 0, skipped: true };
      }
      if (!isAdmin && instructorId && instructorId !== uid) {
        return { merged: 0, skipped: true };
      }

      const attendeesCol = ref.collection('attendees');
      let last = null;
      let merged = 0;

      while (true) {
        let q = attendeesCol.orderBy(FieldPath.documentId()).limit(400);
        if (last) q = q.startAfter(last);
        const attendeesSnap = await q.get();
        if (attendeesSnap.empty) break;

        const batch = db.batch();
        for (const doc of attendeesSnap.docs) {
          const dest = canonicalRef.collection('attendees').doc(doc.id);
          batch.set(dest, doc.data() || {}, { merge: true });
          merged += 1;
        }
        await batch.commit();

        last = attendeesSnap.docs[attendeesSnap.docs.length - 1];
        if (attendeesSnap.size < 400) break;
      }

      return { merged, skipped: false };
    }

    let mergedAttendees = 0;
    const deleted = [];
    const failed = [];

    // Merge attendees first.
    for (const sessionId of sessionIds) {
      if (sessionId === canonicalSessionId) continue;
      try {
        const res = await mergeAttendeesFromSession(sessionId);
        mergedAttendees += res.merged;
      } catch (error) {
        failed.push({ sessionId, step: 'merge-attendees', error: error && error.message ? String(error.message) : String(error) });
      }
    }

    // Then delete old attempt sessions (including their subcollections).
    for (const sessionId of sessionIds) {
      if (sessionId === canonicalSessionId) continue;
      try {
        const res = await deleteAttendanceSessionById({ db, sessionId });
        if (res.deleted) deleted.push(sessionId);
      } catch (error) {
        failed.push({ sessionId, step: 'delete', error: error && error.message ? String(error.message) : String(error) });
      }
    }

    return {
      ok: true,
      canonicalSessionId,
      requestedCount: sessionIds.length,
      mergedAttendees,
      deletedCount: deleted.length,
      deletedIds: deleted,
      failedCount: failed.length,
      failed,
    };
  }
);
