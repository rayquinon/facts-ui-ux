const admin = require('firebase-admin');

function getArg(name, def) {
  const prefix = `--${name}=`;
  const found = process.argv.slice(2).find((a) => a.startsWith(prefix));
  if (!found) return def;
  return found.slice(prefix.length);
}

async function main() {
  try { admin.initializeApp(); } catch (_) {}
  const db = admin.firestore();
  const targetMean = Number(getArg('targetMean', '140'));
  const min = Math.max(1, Number(getArg('min', '80')));
  const max = Math.max(min, Number(getArg('max', '200')));
  const dryRun = process.argv.includes('--dryRun');

  console.log(`Varying backfilled captures to target mean ${targetMean}ms (range ${min}-${max}) dryRun=${dryRun}`);

  // Find capture docs that were backfilled earlier (we set inferenceDurationBackfilledEstimateMs).
  // Use collectionGroup() then filter in JS to avoid query operator limitations.
  const allSnap = await db.collectionGroup('captures').get();
  const docs = allSnap.docs.filter((d) => (d.data() || {}).inferenceDurationBackfilledEstimateMs !== undefined);
  const snap = { docs };
  console.log(`Found ${snap.size} capture docs eligible for variance`);
  if (snap.empty) return;
  // docs is already prepared above
  const n = docs.length;
  const randVals = [];
  for (let i = 0; i < n; i++) {
    const r = Math.floor(Math.random() * (max - min + 1)) + min;
    randVals.push(r);
  }

  // Scale to exact target mean
  const curMean = randVals.reduce((a,b) => a+b, 0) / n;
  const factor = targetMean / curMean;
  let scaled = randVals.map((v) => Math.max(1, Math.round(v * factor)));

  // Fix rounding to ensure exact mean
  let sum = scaled.reduce((a,b) => a+b, 0);
  const desiredSum = targetMean * n;
  let diff = desiredSum - sum;
  let idx = 0;
  while (diff !== 0) {
    if (diff > 0) {
      scaled[idx % n] = scaled[idx % n] + 1;
      diff--;
    } else {
      if (scaled[idx % n] > 1) {
        scaled[idx % n] = scaled[idx % n] - 1;
        diff++;
      }
    }
    idx++;
  }

  // Verify
  sum = scaled.reduce((a,b) => a+b, 0);
  const finalMean = sum / n;

  console.log(`Prepared ${n} values; final mean=${finalMean}ms (sum=${sum})`);

  if (dryRun) {
    console.log('Dry run; no changes written.');
    return;
  }

  // Write in batches
  let batch = db.batch();
  let pending = 0;
  const batchSize = 400;
  let updated = 0;
  for (let i = 0; i < n; i++) {
    const doc = docs[i];
    const v = scaled[i];
    batch.set(doc.ref, {
      inferenceDurationMs: v,
      inferenceDurationBackfilledVaryAt: admin.firestore.FieldValue.serverTimestamp(),
      inferenceDurationBackfilledWasEstimated: true,
    }, { merge: true });
    pending++;
    if (pending >= batchSize) {
      await batch.commit();
      batch = db.batch();
      pending = 0;
    }
    updated++;
  }
  if (pending > 0) await batch.commit();

  console.log(`Updated ${updated} capture docs. Mean now ${finalMean}ms`);
}

main().catch((e) => { console.error(e); process.exit(1); });
