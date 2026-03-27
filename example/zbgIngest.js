// example/zbgIngest.js
// Firebase Cloud Functions v2 (Node 20) — HTTP ingestion endpoint.
// Deployed as exports.zbgIngest in the project's functions/index.js.
//
// Receives GPS fix batches posted by FBG's native HTTP transport, validates
// them, runs a server-side zone state machine to compute ENTER/DWELL/EXIT
// events across batch boundaries, and writes breadcrumbs and geofence events
// to Firestore. Also handles native HTTP geofence events posted by FBG when
// the app is in background or terminated state.
//
// This file is extracted here for review purposes. In production it lives
// alongside the rest of the Cloud Functions in functions/index.js.

const { onRequest } = require('firebase-functions/v2/https');
const { setGlobalOptions } = require('firebase-functions/v2');
const admin = require('firebase-admin');
const ngeohash = require('ngeohash');

setGlobalOptions({ region: 'us-central1' });

admin.initializeApp();
const db = admin.firestore();
const FieldValue = admin.firestore.FieldValue;

// --- helpers ---
function gh7(lat, lng) {
  try {
    return ngeohash.encode(lat, lng, 7);
  } catch {
    return null;
  }
}

// Normalize FBG payload to an array of locations.
// Handles:
//  - body.locations = [loc, ...]
//  - body.location  = [loc, ...]
//  - body.location  = loc
function normalizeLocations(body) {
  if (Array.isArray(body.locations)) return body.locations;
  if (Array.isArray(body.location)) return body.location;
  if (body.location && typeof body.location === 'object') return [body.location];
  return [];
}

// Get uid from params or from the first location's extras.
function getUid(body) {
  const fromParams =
    body?.params?.uid ||
    body?.extras?.uid ||
    body?.geofence?.location?.extras?.uid;
  if (fromParams) return fromParams.toString();

  if (Array.isArray(body.location) && body.location.length > 0) {
    const u = body.location[0]?.extras?.uid;
    if (u) return u.toString();
  }
  if (Array.isArray(body.locations) && body.locations.length > 0) {
    const u = body.locations[0]?.extras?.uid;
    if (u) return u.toString();
  }
  if (body.location && typeof body.location === 'object') {
    const u = body.location.extras?.uid;
    if (u) return u.toString();
  }
  return '';
}

// Get regionId from params or from first location's extras.
function getRegionId(body) {
  const fromParams =
    body?.params?.regionId ||
    body?.extras?.regionId ||
    body?.geofence?.location?.extras?.regionId;
  if (fromParams) return fromParams.toString();

  if (Array.isArray(body.location) && body.location.length > 0) {
    const r = body.location[0]?.extras?.regionId;
    if (r) return r.toString();
  }
  if (Array.isArray(body.locations) && body.locations.length > 0) {
    const r = body.locations[0]?.extras?.regionId;
    if (r) return r.toString();
  }
  if (body.location && typeof body.location === 'object') {
    const r = body.location.extras?.regionId;
    if (r) return r.toString();
  }
  return null;
}

// In-memory cache for gatesAllow — avoids a Firestore read on every request.
const _gatesCache = {
  runtime: { data: null, expiresAt: 0 },
};
const _GATES_TTL_MS = 60 * 1000; // 60 seconds

async function _cachedRuntime() {
  const now = Date.now();
  if (_gatesCache.runtime.data !== null && now < _gatesCache.runtime.expiresAt) {
    return _gatesCache.runtime.data;
  }
  const snap = await db.doc('appConfig/runtime').get();
  const data = snap.exists ? (snap.data() || {}) : null;
  _gatesCache.runtime = { data, expiresAt: now + _GATES_TTL_MS };
  return data;
}

// Gate for breadcrumbs: checks breadcrumbs.enabled + regionGate.
async function gatesAllow({ regionId }) {
  const runtime = await _cachedRuntime();
  if (!runtime) return { ok: false, reason: 'missing runtime' };

  const breadcrumbs = runtime.breadcrumbs ?? {};
  if (breadcrumbs.enabled !== true) {
    return { ok: false, reason: 'breadcrumbs disabled' };
  }

  const regionGate = runtime.regionGate ?? {};
  if (regionGate.enabled === true && regionId) {
    const allowed = Array.isArray(regionGate.allowed_regions)
      ? regionGate.allowed_regions
      : [];
    if (!allowed.includes(regionId)) {
      return { ok: false, reason: 'region not allowed' };
    }
  }
  return { ok: true };
}

// Gate for geofence events: checks regionGate only — NOT breadcrumbs.enabled.
// Geofence events are low-volume and critical (the only write path in terminated
// state), so they must not be silenced by the breadcrumb master switch.
async function geofenceGateAllow({ regionId }) {
  const runtime = await _cachedRuntime();
  if (!runtime) return { ok: false, reason: 'missing runtime' };

  const regionGate = runtime.regionGate ?? {};
  if (regionGate.enabled === true && regionId) {
    const allowed = Array.isArray(regionGate.allowed_regions)
      ? regionGate.allowed_regions
      : [];
    if (!allowed.includes(regionId)) {
      return { ok: false, reason: 'region not allowed' };
    }
  }
  return { ok: true };
}

// ─────────────────────────────────────────────────────────────
// Geofence zone detection utilities
// ─────────────────────────────────────────────────────────────

function haversineM(lat1, lng1, lat2, lng2) {
  const R = 6371000;
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLng = (lng2 - lng1) * Math.PI / 180;
  const a = Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) * Math.sin(dLng / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

// Like computeZoneId but adds a buffer beyond the fence edge when a prevZoneId
// is known. Prevents flickering EXIT when GPS is near the fence boundary.
const EXIT_BUFFER_M = 30;
function computeZoneIdWithBuffer(lat, lng, fences, prevZoneId) {
  for (const f of fences) {
    if (haversineM(lat, lng, f.lat, f.lng) <= f.radiusM) return f.id;
  }
  if (prevZoneId) {
    const prev = fences.find(f => f.id === prevZoneId);
    if (prev && haversineM(lat, lng, prev.lat, prev.lng) <= prev.radiusM + EXIT_BUFFER_M) {
      return prevZoneId;
    }
  }
  return null;
}

// Module-level fence index cache keyed by regionId. 5-min TTL.
const _fenceCache = {};
const _FENCE_CACHE_TTL_MS = 5 * 60 * 1000;

async function loadFenceIndex(regionId) {
  const c = _fenceCache[regionId];
  if (c && (Date.now() - c.fetchedAt) < _FENCE_CACHE_TTL_MS) return c.fences;
  const snap = await db.doc(`regions/${regionId}/meta/geofenceIndex`).get();
  const fences = (snap.data()?.fences ?? []).filter(
    f => f.lat != null && f.lng != null && f.radiusM != null
  );
  _fenceCache[regionId] = { fences, fetchedAt: Date.now() };
  return fences;
}

// Reads dwell thresholds from the already-cached appConfig/runtime document.
async function loadDwellConfig() {
  const runtime = await _cachedRuntime();
  const gd = runtime?.geofenceDetect ?? {};
  return {
    dwellRequiredS: gd.dwell_required_s ?? 60,
    dwellEveryS:    gd.dwell_every_s    ?? 0,
  };
}

// ─────────────────────────────────────────────────────────────
// zbgIngest — main HTTP endpoint
// ─────────────────────────────────────────────────────────────

exports.zbgIngest = onRequest({ cors: true }, async (req, res) => {
  try {
    if (req.method !== 'POST') {
      return res.status(405).send('Method not allowed');
    }

    // Auth: API key header
    const apiKey = req.get('X-Api-Key');
    const expected = process.env.ZBG_API_KEY;
    if (!expected || apiKey !== expected) {
      return res.status(401).send('Unauthorized');
    }

    const body = req.body || {};

    const uid = getUid(body);
    const regionId = getRegionId(body);

    if (!uid) {
      console.warn('zbgIngest WARNING: Missing uid, dropping payload');
      return res.status(400).send('Missing uid');
    }

    const batch = db.batch();
    let count = 0;

    // Extract mode from extras — present in all new-build payloads.
    const mode =
      body?.geofence?.location?.extras?.mode ??
      (Array.isArray(body?.location) ? body.location[0]?.extras?.mode : null) ??
      body?.location?.extras?.mode ??
      (Array.isArray(body?.locations) ? body.locations[0]?.extras?.mode : null) ??
      null;

    try {
      console.log(
        'zbgIngest INFO sample payload',
        JSON.stringify(
          {
            hasLocation: !!body.location || !!body.locations,
            hasArrayLocation:
              Array.isArray(body.location) || Array.isArray(body.locations),
            mode,
          },
          null,
          0
        )
      );
    } catch (_) {
      // ignore logging errors
    }

    // Geofence events use their own gate (regionGate only — not breadcrumbs.enabled).
    // This ensures native HTTP geofence events (the only write path in terminated state)
    // are never silenced by the breadcrumb master switch.
    if (body.geofence) {
      const geoGate = await geofenceGateAllow({ regionId });
      if (geoGate.ok) {
        const g = body.geofence;
        const ts = g?.location?.timestamp
          ? new Date(g.location.timestamp)
          : new Date();
        const tsIso = ts.toISOString();

        const geofenceDoc = {
          uid,
          regionId: regionId || null,
          ts_iso: tsIso,
          event: g.action || null,
          zoneId: g.identifier || null,
          source: 'bg_native_http',
          mode: mode || null,
        };

        // Compute dwell_seconds on EXIT events by looking up the most recent
        // ENTER for this uid + zoneId. Fills the gap that exists when the app is
        // terminated — the Dart path has in-memory enteredAt; zbgIngest does not.
        if (g.action === 'EXIT' && g.identifier && uid) {
          const enterSnap = await db.collection('geofence_events')
            .where('uid', '==', uid)
            .where('zoneId', '==', g.identifier)
            .where('event', '==', 'ENTER')
            .orderBy('ts_iso', 'desc')
            .limit(1)
            .get();
          if (!enterSnap.empty) {
            const enterTs = new Date(enterSnap.docs[0].data().ts_iso);
            const dwellSeconds = Math.round((ts - enterTs) / 1000);
            if (dwellSeconds > 0) geofenceDoc.dwell_seconds = dwellSeconds;
          }
        }

        batch.set(db.collection('geofence_events').doc(), geofenceDoc);
        count++;
      }
    }

    // Breadcrumb / location path uses full gate (breadcrumbs.enabled + regionGate).
    const breadcrumbGate = await gatesAllow({ regionId });
    const items = breadcrumbGate.ok ? normalizeLocations(body) : [];

    // Load fence geometry only when breadcrumb gate passed and there are locations.
    const fences = (breadcrumbGate.ok && regionId) ? await loadFenceIndex(regionId) : [];

    // Sort ascending so transitions are detected in chronological order.
    const sortedItems = [...items].sort(
      (a, b) => new Date(a.timestamp) - new Date(b.timestamp)
    );

    // Seed previous zone state and dwell tracking from the user doc.
    //
    // prevZoneId is seeded from users/{uid}.geo_current_zone_id — the GPS-derived
    // zone written by the previous zbgIngest invocation. This is the only value
    // that survives across HTTP batch boundaries, including terminated-state
    // significant-change wakeups where each POST is a single location.
    //
    // geo_current_zone_id is written exclusively by zbgIngest (GPS-derived) —
    // the Dart/native callback path never writes it — so this read is safe.
    let prevZoneId = null;
    let enteredAt = null;
    let lastFiredMilestoneS = 0;

    if (uid) {
      const userSnap = await db.doc(`users/${uid}`).get();
      if (userSnap.exists) {
        const ud = userSnap.data() || {};
        prevZoneId = ud.geo_current_zone_id ?? null;
        if (prevZoneId !== null) {
          enteredAt = ud.geo_zone_entered_at?.toDate?.() ?? null;
          lastFiredMilestoneS = ud.geo_last_milestone_s ?? 0;
        }
      }
    }

    // Load dwell thresholds from cached runtime config.
    const dwellCfg = fences.length > 0 ? await loadDwellConfig() : { dwellRequiredS: 60, dwellEveryS: 0 };

    for (const loc of sortedItems) {
      const ts = loc?.timestamp ? new Date(loc.timestamp) : new Date();
      const tsIso = ts.toISOString();

      const lat = loc?.coords?.latitude ?? null;
      const lng = loc?.coords?.longitude ?? null;
      const acc = loc?.coords?.accuracy ?? null;

      if (lat == null || lng == null) continue;

      const precomputeInside = loc?.extras?.inside_zone ?? null;
      const precomputeZoneId = loc?.extras?.zoneId ?? null;
      const activityType = loc?.activity?.type ?? null;

      // Compute zone from GPS coordinates with EXIT hysteresis buffer.
      const committedZoneId = fences.length > 0
        ? computeZoneIdWithBuffer(lat, lng, fences, prevZoneId)
        : null;

      // Write geofence transition events.
      if (prevZoneId === null && committedZoneId !== null) {
        // ENTER
        batch.set(db.collection('geofence_events').doc(), {
          uid, regionId: regionId || null, ts_iso: tsIso,
          event: 'ENTER', zoneId: committedZoneId,
          source: 'bg_native_http_computed',
        });
        count++;
        enteredAt = ts;
        lastFiredMilestoneS = 0;
      } else if (prevZoneId !== null && committedZoneId === null) {
        // EXIT
        const dwellSecs = enteredAt ? Math.floor((ts - enteredAt) / 1000) : null;
        const exitDoc = { uid, regionId: regionId || null, ts_iso: tsIso,
          event: 'EXIT', zoneId: prevZoneId, source: 'bg_native_http_computed' };
        if (dwellSecs != null) exitDoc.dwell_seconds = dwellSecs;
        batch.set(db.collection('geofence_events').doc(), exitDoc);
        count++;
        enteredAt = null;
        lastFiredMilestoneS = 0;
      } else if (prevZoneId !== null && committedZoneId !== null && prevZoneId !== committedZoneId) {
        // Zone-to-zone: implicit EXIT from old zone + ENTER new zone.
        const dwellSecs = enteredAt ? Math.floor((ts - enteredAt) / 1000) : null;
        const exitDoc = { uid, regionId: regionId || null, ts_iso: tsIso,
          event: 'EXIT', zoneId: prevZoneId, source: 'bg_native_http_computed' };
        if (dwellSecs != null) exitDoc.dwell_seconds = dwellSecs;
        batch.set(db.collection('geofence_events').doc(), exitDoc);
        count++;
        batch.set(db.collection('geofence_events').doc(), {
          uid, regionId: regionId || null, ts_iso: tsIso,
          event: 'ENTER', zoneId: committedZoneId, source: 'bg_native_http_computed',
        });
        count++;
        enteredAt = ts;
        lastFiredMilestoneS = 0;
      }

      // Dwell milestone check — fires when continuing inside the same zone.
      if (enteredAt && committedZoneId !== null && committedZoneId === prevZoneId) {
        const elapsedS = Math.floor((ts - enteredAt) / 1000);
        const { dwellRequiredS, dwellEveryS } = dwellCfg;

        // Initial dwell threshold.
        if (lastFiredMilestoneS === 0 && elapsedS >= dwellRequiredS) {
          const dwellDoc = { uid, regionId: regionId || null, ts_iso: tsIso,
            event: 'DWELL', zoneId: committedZoneId,
            dwell_seconds: elapsedS, source: 'bg_native_http_computed' };
          batch.set(db.collection('geofence_events').doc(), dwellDoc);
          count++;
          lastFiredMilestoneS = dwellRequiredS;
        }

        // Repeating milestones — else if prevents double-firing for the same breadcrumb.
        else if (dwellEveryS > 0 && lastFiredMilestoneS >= dwellRequiredS) {
          const highestMilestone = Math.floor(elapsedS / dwellEveryS) * dwellEveryS;
          if (highestMilestone > lastFiredMilestoneS) {
            const dwellDoc = { uid, regionId: regionId || null, ts_iso: tsIso,
              event: 'DWELL', zoneId: committedZoneId,
              dwell_seconds: elapsedS, source: 'bg_native_http_computed' };
            batch.set(db.collection('geofence_events').doc(), dwellDoc);
            count++;
            lastFiredMilestoneS = highestMilestone;
          }
        }
      }

      prevZoneId = committedZoneId;

      // In geofence-only mode, suppress breadcrumbs when outside all fences.
      if (mode === 'geofence_only' && committedZoneId === null) continue;

      // Write breadcrumb with computed zone + precompute snapshot for divergence analysis.
      batch.set(
        db.collection('breadcrumbs').doc(`${uid}_${tsIso}`),
        {
          uid,
          regionId: regionId || null,
          ts_iso: tsIso,
          lat,
          lng,
          accuracy_m: acc,
          geohash_p7: gh7(lat, lng),
          zoneId: committedZoneId,
          inside_zone: committedZoneId !== null,
          precompute_inside_zone: precomputeInside,
          precompute_zone_id: precomputeZoneId,
          activity_type: activityType,
          source: 'bg_native_http',
          mode: mode || null,
        },
        { merge: false }
      );
      count++;
    }

    if (count === 0) {
      return res.status(200).json({ ok: true, ignored: true, count: 0 });
    }

    // Update breadcrumb timestamps on user doc so geoWakeupSweep can target users
    // with a breadcrumb gap. Written only when at least one location was accepted.
    //
    // last_breadcrumb_write_ts — server timestamp of this Firestore write.
    //   Answers: "is the device reachable?"
    //
    // last_breadcrumb_ts — device-side GPS fix timestamp from the last location
    //   in this batch. Answers: "how old is the actual location data?"
    //   Can be significantly older than last_breadcrumb_write_ts when sync()
    //   flushes a stale SQLite buffer.
    if (items.length > 0) {
      const lastItem = sortedItems[sortedItems.length - 1];
      const lastActivityType = lastItem?.activity?.type ?? null;
      const lastDeviceTs = lastItem?.timestamp
        ? admin.firestore.Timestamp.fromDate(new Date(lastItem.timestamp))
        : null;
      const userDocFields = { last_breadcrumb_write_ts: FieldValue.serverTimestamp() };
      if (lastDeviceTs) userDocFields.last_breadcrumb_ts = lastDeviceTs;
      if (lastActivityType !== null) userDocFields.last_activity_type = lastActivityType;
      // Cache zone state so the next invocation can restore prevZoneId, enteredAt,
      // and lastFiredMilestoneS from a single user doc read instead of collection queries.
      userDocFields.geo_current_zone_id = prevZoneId ?? null;
      if (enteredAt) {
        userDocFields.geo_zone_entered_at = admin.firestore.Timestamp.fromDate(enteredAt);
      } else {
        userDocFields.geo_zone_entered_at = null;
      }
      userDocFields.geo_last_milestone_s = lastFiredMilestoneS;
      batch.set(db.doc(`users/${uid}`), userDocFields, { merge: true });
    }

    await batch.commit();
    return res.status(200).json({ ok: true, count });
  } catch (e) {
    console.error(e);
    return res.status(500).send('Server error');
  }
});
