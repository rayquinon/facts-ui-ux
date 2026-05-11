const admin = require('firebase-admin');

function parseArg(name, fallback) {
  const prefix = `--${name}=`;
  const found = process.argv.slice(2).find((arg) => arg.startsWith(prefix));
  if (!found) return fallback;
  const value = found.slice(prefix.length);
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback;
}

async function main() {
  try {
    admin.initializeApp();
  } catch (_) {
    // ignore if already initialized
  }

  const db = admin.firestore();
  const estimatedMs = Math.max(1, Math.round(parseArg('estimatedMs', 140)));
  const dryRun = process.argv.includes('--dryRun');

  console.log(`Backfilling missing inferenceDurationMs with ${estimatedMs}ms (dryRun=${dryRun})`);

  const snap = await db.collectionGroup('captures').get();
  let scanned = 0;
  let updated = 0;
  let alreadySet = 0;
  const batchSize = 400;
  let batch = db.batch();
  let pending = 0;

  for (const doc of snap.docs) {
    scanned++;
    const data = doc.data() || {};
    const value = data.inferenceDurationMs;
    if (typeof value === 'number' && Number.isFinite(value) && value > 0) {
      alreadySet++;
      continue;
    }

    updated++;
    if (!dryRun) {
      batch.set(
        doc.ref,
        {
          inferenceDurationMs: estimatedMs,
          inferenceDurationBackfilledAt: admin.firestore.FieldValue.serverTimestamp(),
          inferenceDurationBackfilledEstimateMs: estimatedMs,
        },
        { merge: true }
      );
      pending++;
      if (pending >= batchSize) {
        await batch.commit();
        batch = db.batch();
        pending = 0;
      }
    }
  }

  if (!dryRun && pending > 0) {
    await batch.commit();
  }

  console.log(
    JSON.stringify(
      {
        ok: true,
        estimatedMs,
        dryRun,
        scanned,
        alreadySet,
        updated,
      },
      null,
      2,
    ),
  );
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
