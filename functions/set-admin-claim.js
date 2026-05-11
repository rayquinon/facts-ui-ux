#!/usr/bin/env node
/**
 * Simple script to set admin claim on a user account.
 * Usage: node set-admin-claim.js <email-or-uid>
 */

const { initializeApp, cert } = require('firebase-admin/app');
const { getAuth } = require('firebase-admin/auth');
const { getFirestore } = require('firebase-admin/firestore');
const path = require('path');

// Initialize Firebase Admin SDK using service account
const serviceAccountPath = path.join(__dirname, 'facts-ui-ux-firebase-adminsdk-key.json');

try {
  initializeApp({
    credential: cert(serviceAccountPath),
  });
} catch (error) {
  console.error('❌ Failed to initialize Firebase Admin SDK');
  console.error('Make sure facts-ui-ux-firebase-adminsdk-key.json exists in the functions folder');
  process.exit(1);
}

const auth = getAuth();
const db = getFirestore();

async function setAdminClaim(emailOrUid) {
  try {
    console.log(`\n🔍 Looking up user: ${emailOrUid}...`);
    
    let userRecord;
    
    // Try to get by UID first, then by email
    try {
      userRecord = await auth.getUser(emailOrUid);
      console.log(`✅ Found user by UID: ${userRecord.email}`);
    } catch (e) {
      userRecord = await auth.getUserByEmail(emailOrUid);
      console.log(`✅ Found user by email: ${userRecord.email}`);
    }

    const uid = userRecord.uid;
    const email = userRecord.email;

    // Check if user already has admin claim
    const existingClaims = userRecord.customClaims || {};
    if (existingClaims.admin === true || existingClaims.admin === 'true') {
      console.log(`ℹ️  User ${email} already has admin claim`);
      return;
    }

    // Set admin claim
    console.log(`\n🔐 Setting admin claim for ${email}...`);
    await auth.setCustomUserClaims(uid, { ...existingClaims, admin: true });
    console.log(`✅ Admin claim set successfully!`);

    // Record in Firestore
    console.log(`\n📝 Recording in Firestore...`);
    await db.collection('users').doc(uid).set(
      {
        adminClaimSetAt: new Date(),
        adminClaimSetVia: 'cli-script',
      },
      { merge: true }
    );
    console.log(`✅ Firestore record updated`);

    console.log(`\n✨ Done! User ${email} (${uid}) now has admin privileges.`);
    console.log(`\n📱 Next steps:`);
    console.log(`   1. Close the Flutter app completely`);
    console.log(`   2. Reopen the app`);
    console.log(`   3. Log in again`);
    console.log(`   4. Go to Student Import - the warning should be gone`);
    console.log(`   5. Try uploading a CSV\n`);

  } catch (error) {
    console.error(`\n❌ Error: ${error.message}`);
    process.exit(1);
  }
}

// Get email/UID from command line argument
const emailOrUid = process.argv[2];

if (!emailOrUid) {
  console.error('\n❌ Usage: node set-admin-claim.js <email-or-uid>');
  console.error('\nExample:');
  console.error('   node set-admin-claim.js admin@example.com');
  console.error('   node set-admin-claim.js abc123xyz\n');
  process.exit(1);
}

setAdminClaim(emailOrUid).then(() => process.exit(0));
