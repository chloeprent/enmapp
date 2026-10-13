-- Read-only: page loads vs visitors since launch (13 Oct, Philippines time), tests excluded.
-- == U1. Since launch
SELECT count(*) AS page_loads, count(DISTINCT visitor) AS visitors,
       count(DISTINCT visitor) FILTER (WHERE started) AS started,
       count(DISTINCT visitor) FILTER (WHERE session_id IS NOT NULL) AS completed,
       count(*) FILTER (WHERE vid IS NOT NULL) AS loads_with_browser_id
FROM (SELECT r.*, (SELECT e.meta ->> 'vid' FROM enm_quiz_events e WHERE e.run_id = r.run_id AND e.meta ? 'vid' LIMIT 1) AS vid
      FROM enm_quiz_runs_v r
      WHERE r.first_at >= '2026-10-12T16:00:00Z' AND NOT enm_is_test_email(r.email)) x;
