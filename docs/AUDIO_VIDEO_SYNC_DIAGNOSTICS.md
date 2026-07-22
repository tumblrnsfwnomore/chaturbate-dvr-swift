# Audio/Video Sync Issue Analysis Guide

When you encounter out-of-sync audio and video in specific recordings, use this guide to diagnose the root cause.

## Quick Diagnosis

### 1. **Check Recording Logs**

Search your app logs for `[sync-diag]` markers:

```code
[sync-diag] Video: 125.3s, Audio: 125.8s, Lead: 0.50s, Max: 1.20s, Drifts: 1
```

This tells you:

- **Video duration**: 125.3 seconds written at that moment
- **Audio duration**: 125.8 seconds ahead
- **Current lead**: 0.5 seconds (within 0.75s threshold, so not causing issues)
- **Max lead observed**: 1.2 seconds (exceeded threshold at some point!)  
- **Drifts**: Number of times audio had to wait for video to catch up

**If Drifts > 0**: Audio lead exceeded 0.75s threshold and segments were deferred.

### 2. **Check Recording Ledger Events**

Query the recording ledger for sync diagnostics:

```sql
SELECT recording_id, created_at, message 
FROM recording_events 
WHERE event_type = 'audio_video_sync_diagnostics'
  AND recording_id = <id>
ORDER BY created_at DESC;
```

Output examples:

```code
[sync_drifts=1,max_audio_lead=0.82s]   -- Single brief drift
[sync_drifts=5,max_audio_lead=2.10s]   -- Sustained drift issue
```

### 3. **Identify Problem Files**

Find recordings with sync drift events:

```sql
SELECT 
    r.file_path,
    r.started_at,
    r.status,
    COUNT(e.id) as drift_event_count,
    GROUP_CONCAT(e.message) as drift_details
FROM recordings r
JOIN recording_events e ON r.id = e.recording_id
WHERE e.event_type = 'audio_video_sync_diagnostics'
  AND r.status IN ('completed', 'completed_invalid')
GROUP BY r.id
ORDER BY r.started_at DESC
LIMIT 20;
```

## Understanding the Sync Mechanism

The app uses split audio when the HLS stream provides separate audio/video playlists:

- Video segments are written immediately when downloaded
- Audio segments are deferred if they run >0.75 seconds ahead
- If audio gets too far ahead, it waits for the next polling cycle

### Why Drifts Happen

1. **Different segment durations** between audio and video playlists
   - Video might use 6s segments while audio uses 10s
   - Over time, timings diverge slightly

2. **Network variations**
   - One stream has higher latency than the other
   - Temporary CDN routing differences

3. **HLS playlist updates**
   - Audio/video playlists aren't perfectly synchronized
   - One stream refreshes ahead of the other

4. **Timestamp discontinuities**
   - Stream switches (e.g., bitrate change) cause PTS jumps
   - Audio and video handle discontinuities differently

## Analyzing Specific Cases

### Case 1: Single Drift Event (Drifts: 1)

- Likely transient network variation
- Usually resolves itself in next segment polling cycle
- File often plays back fine

### Case 2: Multiple Drifts (Drifts: 3-5)

- More sustained sync issue
- Audio lead persists across multiple deferral events
- File may have subtle out-of-sync sections

### Case 3: Many Drifts + High Max Lead (Drifts: 10+, Max: 2-3s)

- Serious sync degradation
- Streams have fundamentally different pacing
- File likely has noticeable out-of-sync sections
- **App automatically flags for retime fallback**

## Automatic Remediation

Files with `Drifts > 0` are automatically marked `preferRetimingOnFailure = true`:

- Passthrough MP4 export attempted first (fastest)
- If passthrough validation fails → retime with ffmpeg (regenerates both audio and video timestamps)
- Retime normalizes both timelines, fixing sync issues

Check for these events in the ledger:

```sql
SELECT message FROM recording_events 
WHERE event_type IN ('retime_repair_applied', 'remux_skipped')
  AND recording_id = <id>;
```

## Finding Problematic Channels/Streams

Pattern analysis to identify which channels/streamers have persistent sync issues:

```sql
SELECT 
    c.username,
    COUNT(DISTINCT r.id) as recordings_with_drift,
    ROUND(AVG(SUBSTR(e.message, INSTR(e.message, 'sync_drifts=') + 11, 
        INSTR(SUBSTR(e.message, INSTR(e.message, 'sync_drifts=') + 11), ',') - 1)), 1) as avg_drifts,
    MIN(r.started_at) as first_drift_date,
    MAX(r.started_at) as last_drift_date
FROM channels c
JOIN recordings r ON c.id = r.channel_id
JOIN recording_events e ON r.id = e.recording_id
WHERE e.event_type = 'audio_video_sync_diagnostics'
GROUP BY c.username
ORDER BY recordings_with_drift DESC
LIMIT 20;
```

High numbers here indicate either:

- **Streamer setup issue**: They're using a stream encoder that splits audio/video poorly
- **Broadcaster CDN issue**: Their content delivery has timing problems
- **Network path issue**: Route to this broadcaster has higher variability

## When Diagnostics Help Most

✅ **Use these diagnostics when:**

- You see out-of-sync audio/video on some but not all recordings
- You want to identify *which* recordings might have issues without playing them all
- You're trying to spot patterns (same channel, same time, etc.)
- You need to decide whether a file needs repair

❌ **Limitations:**

- Diagnostics track *lead deferral events*, not final output sync
- A file with high drifts *might* still play back fine if segments align in the end
- Silent failures (drifts that don't get corrected) aren't directly detected
- You still need to spot-check problem files by playing them

## Next Steps

1. **Identify a problem file** using diagnostics above
2. **Check the file**: open in media player and scrub to spot sync issues
3. **Examine ledger events** for that recording:
   - Look for `retime_repair_applied` (already retimed)
   - Look for `remux_skipped` (retime failed, kept original)
4. **Consider manual repair** if auto-retime failed:

   ```bash
   ffmpeg -i problem.mp4 -c:v libx264 -preset veryfast -crf 20 \
     -c:a aac -b:a 192k -ar 48000 -ac 2 -movflags +faststart repaired.mp4
   ```
