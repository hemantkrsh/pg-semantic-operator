-- System One operator. Demo script.
-- Run: docker compose exec postgres-db psql -U systemone -d systemone -f /demo/demo_queries.sql

\timing on
\pset null '∅'
-- Print every result inline. A pager would hide wide results.
\pset pager off

-- 1. Sample data.
DROP TABLE IF EXISTS user_actions;

CREATE TABLE user_actions (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id    integer     NOT NULL,
    action_log text        NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ON user_actions (user_id, created_at);

-- Users 101 and 104 are healthy. User 102 is leaving. User 103 is angry about billing.
INSERT INTO user_actions (user_id, action_log, created_at) VALUES
    (101, 'Logged in from the iOS app and opened the weekly dashboard.',              now() - interval '6 days'),
    (101, 'Exported the Q3 revenue report to CSV and shared it with finance.',        now() - interval '2 days'),
    (102, 'Visited the account cancellation page twice in one session.',              now() - interval '5 days'),
    (102, 'Asked support how to export all data before closing the account.',         now() - interval '3 days'),
    (102, 'Downgraded plan from Pro to Free and removed saved payment method.',       now() - interval '1 day'),
    (103, 'Payment failed because the card was declined.',                            now() - interval '4 days'),
    (103, 'Opened a ticket: charged twice this month, very frustrated, wants refund.', now() - interval '2 days'),
    (104, 'Invited three teammates and created a shared workspace.',                  now() - interval '3 days'),
    (104, 'Upgraded to the Team plan and enabled single sign-on.',                    now() - interval '1 day'),
    (101, 'Updated notification preferences to daily digest.',                       now() - interval '40 days');


-- 2. Churn radar.
-- Each user's stats and ordered actions become one labeled state string.
-- The model judges the whole story, not single rows.
-- Labeled fields and concrete questions give more confident scores.
-- Cheap filters run first. The model only sees users who pass them.
WITH journeys AS (
    SELECT
        user_id,
        count(*)        AS events,
        max(created_at) AS last_seen,
        '[Events (30d)]: ' || count(*)
        || ' | Days Since Last Action: ' || (current_date - max(created_at)::date)
        || ' | Actions: ' || string_agg(action_log, ' → ' ORDER BY created_at) AS state
    FROM user_actions
    WHERE created_at >= now() - interval '30 days'
    GROUP BY user_id
    HAVING count(*) >= 2
)
SELECT
    user_id,
    events,
    last_seen::date AS last_seen,
    -- Same text and question as the filter, so this score comes from the cache.
    round(strands_score(state,
        'Has the user taken concrete steps to cancel, downgrade, or close their account?'
    )::numeric, 3)  AS churn_score,
    state
FROM journeys
WHERE state @@? 'Has the user taken concrete steps to cancel, downgrade, or close their account?'
ORDER BY churn_score DESC;


-- 3. Semantic dashboard.
-- One pass over the log. Each column is a natural language category.
SELECT
    date_trunc('week', created_at)::date AS week,
    count(*)                             AS total_events,
    count(*) FILTER (WHERE action_log @@? 'Does this describe a billing or payment problem?')
                                         AS billing_issues,
    -- Concrete actions score better than guesses about intent.
    count(*) FILTER (WHERE action_log @@? 'Is the user cancelling, downgrading, or closing their account?')
                                         AS churn_signals,
    count(*) FILTER (WHERE action_log @@? 'Does this show the user expanding usage, adding seats, or upgrading?')
                                         AS expansion_signals,
    count(*) FILTER (WHERE action_log @@? 'Is this a routine, low-stakes product action?')
                                         AS routine_activity
FROM user_actions
GROUP BY 1
ORDER BY 1 DESC;


-- 4. Cache check.
-- Run the dashboard again. Every decision now comes from strands_cache.
-- Yes and no use the same threshold as the @@? operator.
WITH t AS (
    SELECT coalesce(nullif(current_setting('strands.threshold', true), ''), '0.5')::double precision AS threshold
)
SELECT question,
       count(*) FILTER (WHERE score >= t.threshold) AS yes,
       count(*) FILTER (WHERE score <  t.threshold) AS no
FROM strands_cache, t
GROUP BY question
ORDER BY yes DESC, question;

-- Tuning knobs, per session:
--   SET strands.threshold = '0.7';   -- Stricter decisions.
--   SET strands.use_cache = 'off';   -- Always ask the model.
