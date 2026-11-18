-- System One operator. Database initialization.
-- Runs once on first start, via docker-entrypoint-initdb.d.

CREATE EXTENSION IF NOT EXISTS plpython3u;

-- Runtime settings. Override per session with SET, or per role with ALTER ROLE.
DO $$
BEGIN
    EXECUTE format('ALTER DATABASE %I SET strands.endpoint = %L',
                   current_database(), 'http://strands-model:8000/v1/systemone');
    EXECUTE format('ALTER DATABASE %I SET strands.threshold = %L',
                   current_database(), '0.5');
    EXECUTE format('ALTER DATABASE %I SET strands.timeout_s = %L',
                   current_database(), '30');
    EXECUTE format('ALTER DATABASE %I SET strands.use_cache = %L',
                   current_database(), 'on');
END
$$;

-- Decision cache. Same text and same question never hit the model twice.
CREATE TABLE IF NOT EXISTS strands_cache (
    cache_key  text PRIMARY KEY,
    question   text NOT NULL,
    score      double precision NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- Raw model score in [0, 1]. Useful for ranking and debugging.
CREATE OR REPLACE FUNCTION strands_score(state_text text, logical_question text)
RETURNS double precision
LANGUAGE plpython3u
VOLATILE STRICT PARALLEL UNSAFE
-- A high cost tells the planner to run cheap predicates first.
COST 10000
AS $$
import hashlib
import requests

# One-time setup per session. Plans and the HTTP session are reused.
if "plans" not in SD:
    SD["plans"] = {
        "config": plpy.prepare("""
            SELECT coalesce(nullif(current_setting('strands.endpoint', true), ''),
                            'http://strands-model:8000/v1/systemone')            AS endpoint,
                   coalesce(nullif(current_setting('strands.timeout_s', true), ''),
                            '30')::double precision                              AS timeout_s,
                   coalesce(nullif(current_setting('strands.use_cache', true), ''),
                            'on')::boolean                                       AS use_cache
        """),
        "get": plpy.prepare(
            "SELECT score FROM strands_cache WHERE cache_key = $1", ["text"]),
        "put": plpy.prepare(
            "INSERT INTO strands_cache (cache_key, question, score) VALUES ($1, $2, $3) "
            "ON CONFLICT (cache_key) DO NOTHING", ["text", "text", "double precision"]),
    }
    SD["http"] = requests.Session()

plans = SD["plans"]
cfg = plpy.execute(plans["config"])[0]

key = hashlib.sha256(f"{logical_question}\x1f{state_text}".encode()).hexdigest()
if cfg["use_cache"]:
    hit = plpy.execute(plans["get"], [key])
    if hit:
        return hit[0]["score"]

payload = {
    "state": state_text,
    "questions": {
        "mvp_check": {
            "type": "noul",
            "instructions": logical_question,
        }
    },
}

try:
    resp = SD["http"].post(cfg["endpoint"], json=payload, timeout=cfg["timeout_s"])
    resp.raise_for_status()
    body = resp.json()
except (requests.RequestException, ValueError) as exc:
    plpy.error(f"strands-model request failed: {exc}")

# Expected shape: {"answers": {"mvp_check": {"type": "noul", "noul": 0.83}}, ...}
# A noul answer near 1 means yes. Near 0 means no.
try:
    score = float(body["answers"]["mvp_check"]["noul"])
except (KeyError, TypeError, ValueError):
    plpy.error("strands-model response has no noul answer",
               detail=str(body)[:500])

if not 0.0 <= score <= 1.0:
    plpy.error(f"strands-model returned out-of-range noul: {score}")

if cfg["use_cache"]:
    plpy.execute(plans["put"], [key, logical_question, score])

return score
$$;

COMMENT ON FUNCTION strands_score(text, text)
    IS 'System One score for a text and a natural language question.';

-- Boolean decision. True when the score meets strands.threshold.
CREATE OR REPLACE FUNCTION strands_decide(state_text text, logical_question text)
RETURNS boolean
LANGUAGE sql
VOLATILE STRICT PARALLEL UNSAFE
COST 10000
AS $$
    SELECT strands_score(state_text, logical_question)
           >= coalesce(nullif(current_setting('strands.threshold', true), ''), '0.5')::double precision
$$;

-- Operator wrapper. Left side is data. Right side is the question.
CREATE OR REPLACE FUNCTION strands_op_match(state_text text, logical_question text)
RETURNS boolean
LANGUAGE sql
VOLATILE STRICT PARALLEL UNSAFE
COST 10000
AS $$
    SELECT strands_decide(state_text, logical_question)
$$;

DROP OPERATOR IF EXISTS @@? (text, text);

CREATE OPERATOR @@? (
    LEFTARG  = text,             -- The column containing your data.
    RIGHTARG = text,             -- The natural language question.
    FUNCTION = strands_op_match  -- The wrapper that runs the model.
);

COMMENT ON OPERATOR @@? (text, text)
    IS 'True when System One answers yes to the question for this text.';
