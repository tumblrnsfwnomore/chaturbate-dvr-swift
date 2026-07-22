#!/bin/bash
# Analyze audio/video sync issues from recording ledger
# Usage: ./analyze-sync-issues.sh [username]

set -e

APPDATA="${HOME}/Library/Application Support/Code/User/globalStorage/github.copilot-chat/history-codicons/chaturbate-dvr"
DB="${APPDATA}/recordings.sqlite"

if [ ! -f "$DB" ]; then
    echo "❌ Database not found: $DB"
    exit 1
fi

USERNAME="${1:-}"

echo "📊 Audio/Video Sync Issue Analysis"
echo "=================================="
echo ""

# Query 1: Recordings with sync drift events
echo "📍 Recordings with Audio/Video Sync Drifts:"
sqlite3 "$DB" <<EOF
.headers on
.mode column
SELECT 
    r.file_path,
    c.username,
    r.started_at,
    r.duration_seconds,
    (SELECT COUNT(*) FROM recording_events e 
     WHERE e.recording_id = r.id 
     AND e.event_type = 'audio_video_sync_diagnostics') as sync_events,
    GROUP_CONCAT(
        CASE 
            WHEN e.event_type = 'audio_video_sync_diagnostics' THEN e.message
        END, '; '
    ) as sync_details
FROM recordings r
JOIN channels c ON r.channel_id = c.id
JOIN recording_events e ON r.id = e.recording_id
WHERE e.event_type = 'audio_video_sync_diagnostics'
    ${USERNAME:+ AND c.username = '$USERNAME'}
GROUP BY r.id
ORDER BY r.started_at DESC
LIMIT 20;
EOF

echo ""
echo "📈 Sync Drift Statistics by Channel:"
sqlite3 "$DB" <<EOF
.headers on
.mode column
SELECT 
    c.username,
    COUNT(DISTINCT r.id) as total_recordings_with_drift,
    COUNT(DISTINCT CASE WHEN e.level = 'WARN' THEN r.id END) as warn_level_count,
    COUNT(DISTINCT CASE WHEN e.level = 'INFO' THEN r.id END) as info_level_count
FROM channels c
JOIN recordings r ON c.id = r.channel_id
JOIN recording_events e ON r.id = e.recording_id
WHERE e.event_type = 'audio_video_sync_diagnostics'
    ${USERNAME:+ AND c.username = '$USERNAME'}
GROUP BY c.username
ORDER BY total_recordings_with_drift DESC;
EOF

echo ""
echo "⏰ Time-based Pattern Analysis (last 7 days):"
sqlite3 "$DB" <<EOF
.headers on
.mode column
SELECT 
    DATE(r.started_at, 'unixepoch') as date,
    COUNT(DISTINCT r.id) as recordings_with_sync_drift,
    ROUND(AVG(r.duration_seconds), 1) as avg_duration_sec
FROM recordings r
JOIN recording_events e ON r.id = e.recording_id
WHERE e.event_type = 'audio_video_sync_diagnostics'
    AND r.started_at > unixepoch('now', '-7 days')
    ${USERNAME:+ AND r.channel_id IN (SELECT id FROM channels WHERE username = '$USERNAME')}
GROUP BY DATE(r.started_at, 'unixepoch')
ORDER BY date DESC;
EOF

echo ""
echo "ℹ️  To view individual sync events for a file:"
echo "   sqlite3 ~/Library/Application\ Support/Code/User/globalStorage/github.copilot-chat/history-codicons/chaturbate-dvr/recordings.sqlite"
echo "   SELECT message FROM recording_events WHERE recording_id = <id> AND event_type = 'audio_video_sync_diagnostics' ORDER BY created_at;"
