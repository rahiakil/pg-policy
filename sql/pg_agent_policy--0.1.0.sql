-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pg_agent_policy" to load this file. \quit

COMMENT ON SCHEMA pg_agent_policy IS
  'Agentic policy language: guardrails, guidance, and session-aware controls';

--------------------------------------------------------------------------------
-- Catalog
--------------------------------------------------------------------------------

CREATE TABLE policies (
    policy_id       bigserial PRIMARY KEY,
    name            text        NOT NULL UNIQUE,
    description     text,
    enabled         boolean     NOT NULL DEFAULT true,
    priority        integer     NOT NULL DEFAULT 100,
    effect          text        NOT NULL CHECK (effect IN ('permit', 'forbid', 'guide')),
    principal_type  text        NOT NULL DEFAULT 'agent',
    principal_id    text        NOT NULL DEFAULT '*',
    action_type     text        NOT NULL DEFAULT 'tool',
    action_id       text        NOT NULL DEFAULT '*',
    resource_type   text        NOT NULL DEFAULT '*',
    resource_id     text        NOT NULL DEFAULT '*',
    condition       jsonb       NOT NULL DEFAULT '{}'::jsonb,
    temporal        jsonb,
    obligations     jsonb       NOT NULL DEFAULT '[]'::jsonb,
    reason          text,
    source_apl      text,
    mode_override   text        CHECK (mode_override IS NULL OR mode_override IN ('enforce', 'log_only', 'guide')),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX policies_match_idx
  ON policies (principal_type, principal_id, action_type, action_id);

COMMENT ON TABLE policies IS
  'Compiled agent policies. Prefer upsert_policy() over direct inserts.';

CREATE TABLE sessions (
    session_id      text        PRIMARY KEY,
    principal_type  text        NOT NULL,
    principal_id    text        NOT NULL,
    attributes      jsonb       NOT NULL DEFAULT '{}'::jsonb,
    opened_at       timestamptz NOT NULL DEFAULT now(),
    last_seen_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE events (
    event_id        bigserial PRIMARY KEY,
    session_id      text        NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
    at              timestamptz NOT NULL DEFAULT now(),
    action_type     text        NOT NULL,
    action_id       text        NOT NULL,
    resource_type   text,
    resource_id     text,
    attributes      jsonb       NOT NULL DEFAULT '{}'::jsonb,
    decision        text
);

CREATE INDEX events_session_at_idx ON events (session_id, at DESC);

CREATE TABLE decision_log (
    log_id          bigserial PRIMARY KEY,
    at              timestamptz NOT NULL DEFAULT now(),
    session_id      text,
    principal_type  text        NOT NULL,
    principal_id    text        NOT NULL,
    action_type     text        NOT NULL,
    action_id       text        NOT NULL,
    resource_type   text,
    resource_id     text,
    context         jsonb       NOT NULL DEFAULT '{}'::jsonb,
    decision        text        NOT NULL,
    matched_policies text[],
    obligations     jsonb       NOT NULL DEFAULT '[]'::jsonb,
    reasons         text[],
    mode            text        NOT NULL
);

CREATE INDEX decision_log_at_idx ON decision_log (at DESC);

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

CREATE TABLE settings (
    key   text PRIMARY KEY,
    value text NOT NULL
);

INSERT INTO settings(key, value) VALUES
  ('enforcement_mode', 'log_only'),
  ('default_decision', 'deny');

CREATE OR REPLACE FUNCTION get_setting(p_key text)
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT value FROM settings WHERE key = p_key;
$$;

CREATE OR REPLACE FUNCTION set_setting(p_key text, p_value text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO settings(key, value) VALUES (p_key, p_value)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
END;
$$;

--------------------------------------------------------------------------------
-- APL parser (intentionally small for v0.1)
--------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION _apl_extract(p_src text, p_pattern text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  m text[];
BEGIN
  m := regexp_match(p_src, p_pattern, 'i');
  IF m IS NULL THEN
    RETURN NULL;
  END IF;
  RETURN m[1];
END;
$$;

CREATE OR REPLACE FUNCTION parse_apl(p_apl text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_effect text;
  v_principal_type text;
  v_principal_id text;
  v_action_type text;
  v_action_id text;
  v_resource_type text;
  v_resource_id text;
  v_reason text;
  v_when text;
  v_temporal text;
  v_condition jsonb := '{}'::jsonb;
  v_temporal_json jsonb := NULL;
  v_obligations jsonb := '[]'::jsonb;
  v_advice text;
  v_pref text;
  parts text[];
  pair text;
  kv text[];
BEGIN
  IF p_apl IS NULL OR btrim(p_apl) = '' THEN
    RAISE EXCEPTION 'APL document is empty';
  END IF;

  -- Fail closed: reject keywords the v0.1 grammar does not implement.
  -- Silently dropping them would compile a weaker policy than the author wrote.
  IF p_apl ~* '\munless\M'
     OR p_apl ~* '\mformerly\M'
     OR p_apl ~* '\msince\M' THEN
    RAISE EXCEPTION
      'APL contains unsupported keyword (fail-closed); v0.1 allows only the documented grammar';
  END IF;

  v_effect := lower(_apl_extract(p_apl, '^\s*(permit|forbid|guide)\b'));
  IF v_effect IS NULL THEN
    RAISE EXCEPTION 'APL must start with permit, forbid, or guide';
  END IF;

  v_principal_type := coalesce(
    _apl_extract(p_apl, 'principal\s+(agent|user|role|service)\s+"([^"]+)"'),
    'agent'
  );
  -- regexp_match with two groups: re-extract properly
  parts := regexp_match(p_apl, 'principal\s+(agent|user|role|service)\s+"([^"]+)"', 'i');
  IF parts IS NOT NULL THEN
    v_principal_type := lower(parts[1]);
    v_principal_id := parts[2];
  ELSE
    parts := regexp_match(p_apl, 'principal\s+"([^"]+)"', 'i');
    IF parts IS NOT NULL THEN
      v_principal_type := 'agent';
      v_principal_id := parts[1];
    ELSE
      v_principal_id := '*';
    END IF;
  END IF;

  parts := regexp_match(p_apl, 'action\s+(tool|sql|data|admin)\s+"([^"]+)"', 'i');
  IF parts IS NOT NULL THEN
    v_action_type := lower(parts[1]);
    v_action_id := parts[2];
  ELSE
    parts := regexp_match(p_apl, 'action\s+"([^"]+)"', 'i');
    IF parts IS NOT NULL THEN
      v_action_type := 'tool';
      v_action_id := parts[1];
    ELSE
      v_action_type := '*';
      v_action_id := '*';
    END IF;
  END IF;

  parts := regexp_match(p_apl, 'resource\s+(table|schema|database|object)\s+"([^"]+)"', 'i');
  IF parts IS NOT NULL THEN
    v_resource_type := lower(parts[1]);
    v_resource_id := parts[2];
  ELSE
    parts := regexp_match(p_apl, 'resource\s+"([^"]+)"', 'i');
    IF parts IS NOT NULL THEN
      v_resource_type := 'object';
      v_resource_id := parts[1];
    ELSE
      v_resource_type := '*';
      v_resource_id := '*';
    END IF;
  END IF;

  v_reason := _apl_extract(p_apl, 'reason\s+"([^"]*)"');

  v_when := _apl_extract(p_apl, 'when\s*\{([^}]*)\}');
  IF v_when IS NOT NULL THEN
    -- support: context.foo == "bar"  AND  context.foo in ["A","B"]
    FOREACH pair IN ARRAY regexp_split_to_array(v_when, '\s+and\s+', 'i')
    LOOP
      pair := btrim(pair);
      IF pair = '' THEN
        CONTINUE;
      END IF;
      kv := regexp_match(pair, 'context\.([A-Za-z0-9_]+)\s+in\s*\[([^\]]*)\]', 'i');
      IF kv IS NOT NULL THEN
        v_condition := v_condition || jsonb_build_object(
          kv[1],
          jsonb_build_object(
            'op', 'in',
            'value', to_jsonb(ARRAY(SELECT btrim(x, ' "') FROM unnest(string_to_array(kv[2], ',')) AS x WHERE btrim(x) <> ''))
          )
        );
        CONTINUE;
      END IF;
      kv := regexp_match(pair, 'context\.([A-Za-z0-9_]+)\s*==\s*"([^"]*)"', 'i');
      IF kv IS NOT NULL THEN
        v_condition := v_condition || jsonb_build_object(
          kv[1],
          jsonb_build_object('op', 'eq', 'value', to_jsonb(kv[2]))
        );
        CONTINUE;
      END IF;
      kv := regexp_match(pair, 'context\.([A-Za-z0-9_]+)\s*==\s*([0-9.]+)', 'i');
      IF kv IS NOT NULL THEN
        v_condition := v_condition || jsonb_build_object(
          kv[1],
          jsonb_build_object('op', 'eq', 'value', to_jsonb(kv[2]::numeric))
        );
        CONTINUE;
      END IF;
      RAISE EXCEPTION
        'APL when-clause has unsupported predicate (fail-closed): %', pair;
    END LOOP;
  END IF;

  v_temporal := _apl_extract(p_apl, 'when\s+temporal\s*\{([^}]*)\}');
  IF v_temporal IS NOT NULL THEN
    kv := regexp_match(v_temporal,
      'count\s*\(\s*action\s*==\s*"([^"]+)"\s*\)\s*within\s+interval\s+''([^'']+)''\s*(>=|>)\s*([0-9]+)',
      'i');
    IF kv IS NOT NULL THEN
      v_temporal_json := jsonb_build_object(
        'op', 'count',
        'action_id', kv[1],
        'within', kv[2],
        'cmp', kv[3],
        'value', kv[4]::int
      );
    ELSE
      RAISE EXCEPTION
        'APL temporal when-clause is not a supported count(...) form (fail-closed)';
    END IF;
  END IF;

  v_advice := _apl_extract(p_apl, 'advice\s+"([^"]*)"');
  IF v_advice IS NOT NULL THEN
    v_obligations := v_obligations || jsonb_build_array(
      jsonb_build_object('type', 'advice', 'value', v_advice)
    );
  END IF;

  v_pref := _apl_extract(p_apl, 'prefer_tool\s+"([^"]*)"');
  IF v_pref IS NOT NULL THEN
    v_obligations := v_obligations || jsonb_build_array(
      jsonb_build_object('type', 'prefer_tool', 'value', v_pref)
    );
  END IF;

  kv := regexp_match(p_apl, 'max_rows\s+([0-9]+)', 'i');
  IF kv IS NOT NULL THEN
    v_obligations := v_obligations || jsonb_build_array(
      jsonb_build_object('type', 'max_rows', 'value', kv[1]::int)
    );
  END IF;

  RETURN jsonb_build_object(
    'effect', v_effect,
    'principal_type', v_principal_type,
    'principal_id', v_principal_id,
    'action_type', v_action_type,
    'action_id', v_action_id,
    'resource_type', v_resource_type,
    'resource_id', v_resource_id,
    'condition', v_condition,
    'temporal', v_temporal_json,
    'obligations', v_obligations,
    'reason', v_reason,
    'source_apl', p_apl
  );
END;
$$;

COMMENT ON FUNCTION parse_apl(text) IS
  'Parse a v0.1 APL document into JSON IR (fail-closed on unsupported keywords/predicates)';

--------------------------------------------------------------------------------
-- Policy management
--------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION upsert_policy(
  p_name text,
  p_apl text,
  p_description text DEFAULT NULL,
  p_priority integer DEFAULT 100,
  p_enabled boolean DEFAULT true
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  ir jsonb;
  id bigint;
BEGIN
  ir := parse_apl(p_apl);
  INSERT INTO policies AS p (
    name, description, enabled, priority, effect,
    principal_type, principal_id, action_type, action_id,
    resource_type, resource_id, condition, temporal,
    obligations, reason, source_apl, updated_at
  ) VALUES (
    p_name, p_description, p_enabled, p_priority, ir->>'effect',
    ir->>'principal_type', ir->>'principal_id', ir->>'action_type', ir->>'action_id',
    ir->>'resource_type', ir->>'resource_id',
    coalesce(ir->'condition', '{}'::jsonb),
    ir->'temporal',
    coalesce(ir->'obligations', '[]'::jsonb),
    ir->>'reason',
    p_apl,
    now()
  )
  ON CONFLICT (name) DO UPDATE SET
    description = EXCLUDED.description,
    enabled = EXCLUDED.enabled,
    priority = EXCLUDED.priority,
    effect = EXCLUDED.effect,
    principal_type = EXCLUDED.principal_type,
    principal_id = EXCLUDED.principal_id,
    action_type = EXCLUDED.action_type,
    action_id = EXCLUDED.action_id,
    resource_type = EXCLUDED.resource_type,
    resource_id = EXCLUDED.resource_id,
    condition = EXCLUDED.condition,
    temporal = EXCLUDED.temporal,
    obligations = EXCLUDED.obligations,
    reason = EXCLUDED.reason,
    source_apl = EXCLUDED.source_apl,
    updated_at = now()
  RETURNING policy_id INTO id;
  RETURN id;
END;
$$;

CREATE OR REPLACE FUNCTION drop_policy(p_name text)
RETURNS boolean
LANGUAGE plpgsql
AS $$
BEGIN
  DELETE FROM policies WHERE name = p_name;
  RETURN FOUND;
END;
$$;

--------------------------------------------------------------------------------
-- Session / events
--------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION open_session(
  p_session_id text,
  p_principal_type text,
  p_principal_id text,
  p_attributes jsonb DEFAULT '{}'::jsonb
)
RETURNS text
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO sessions(session_id, principal_type, principal_id, attributes)
  VALUES (p_session_id, p_principal_type, p_principal_id, coalesce(p_attributes, '{}'::jsonb))
  ON CONFLICT (session_id) DO UPDATE SET
    last_seen_at = now(),
    attributes = EXCLUDED.attributes;
  RETURN p_session_id;
END;
$$;

CREATE OR REPLACE FUNCTION record_event(
  p_session_id text,
  p_action_type text,
  p_action_id text,
  p_resource_type text DEFAULT NULL,
  p_resource_id text DEFAULT NULL,
  p_attributes jsonb DEFAULT '{}'::jsonb,
  p_decision text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  id bigint;
BEGIN
  UPDATE sessions SET last_seen_at = now() WHERE session_id = p_session_id;
  INSERT INTO events(
    session_id, action_type, action_id, resource_type, resource_id, attributes, decision
  ) VALUES (
    p_session_id, p_action_type, p_action_id, p_resource_type, p_resource_id,
    coalesce(p_attributes, '{}'::jsonb), p_decision
  ) RETURNING event_id INTO id;
  RETURN id;
END;
$$;

--------------------------------------------------------------------------------
-- Matching helpers
--------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION _glob_match(p_pattern text, p_value text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT p_pattern = '*' OR p_pattern = p_value;
$$;

CREATE OR REPLACE FUNCTION _condition_holds(p_condition jsonb, p_context jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  r record;
  ctx_val jsonb;
  op text;
  expected jsonb;
BEGIN
  IF p_condition IS NULL OR p_condition = '{}'::jsonb THEN
    RETURN true;
  END IF;

  FOR r IN SELECT * FROM jsonb_each(p_condition)
  LOOP
    op := r.value->>'op';
    expected := r.value->'value';
    ctx_val := p_context -> r.key;

    IF op = 'eq' THEN
      IF ctx_val IS DISTINCT FROM expected
         AND ctx_val IS DISTINCT FROM to_jsonb(expected #>> '{}') THEN
        -- also allow scalar string compare
        IF (ctx_val #>> '{}') IS DISTINCT FROM (expected #>> '{}') THEN
          RETURN false;
        END IF;
      END IF;
    ELSIF op = 'in' THEN
      IF NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(expected) AS e(val)
        WHERE e.val = coalesce(ctx_val #>> '{}', ctx_val::text)
      ) THEN
        RETURN false;
      END IF;
    ELSE
      RETURN false;
    END IF;
  END LOOP;
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION _temporal_holds(
  p_session_id text,
  p_temporal jsonb
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  cnt bigint;
  cmp text;
  need int;
  action text;
  within interval;
BEGIN
  IF p_temporal IS NULL OR p_temporal = 'null'::jsonb THEN
    RETURN true;
  END IF;

  IF p_session_id IS NULL THEN
    RETURN false;
  END IF;

  IF p_temporal->>'op' = 'count' THEN
    action := p_temporal->>'action_id';
    within := (p_temporal->>'within')::interval;
    cmp := p_temporal->>'cmp';
    need := (p_temporal->>'value')::int;
    SELECT count(*) INTO cnt
    FROM events e
    WHERE e.session_id = p_session_id
      AND e.action_id = action
      AND e.at >= now() - within;
    IF cmp = '>=' THEN
      RETURN cnt >= need;
    ELSIF cmp = '>' THEN
      RETURN cnt > need;
    END IF;
  END IF;
  RETURN false;
END;
$$;

--------------------------------------------------------------------------------
-- Evaluate
--------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION evaluate(
  p_principal_type text,
  p_principal_id text,
  p_action_type text,
  p_action_id text,
  p_resource_type text DEFAULT '*',
  p_resource_id text DEFAULT '*',
  p_context jsonb DEFAULT '{}'::jsonb,
  p_session_id text DEFAULT NULL,
  p_raise_on_deny boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  mode text;
  default_decision text;
  rec record;
  matched text[] := ARRAY[]::text[];
  reasons text[] := ARRAY[]::text[];
  obligations jsonb := '[]'::jsonb;
  decision text;
  effective_mode text;
  has_forbid boolean := false;
  has_permit boolean := false;
  has_guide boolean := false;
BEGIN
  mode := coalesce(get_setting('enforcement_mode'), 'log_only');
  default_decision := coalesce(get_setting('default_decision'), 'deny');
  decision := default_decision;

  FOR rec IN
    SELECT *
    FROM policies p
    WHERE p.enabled
      AND _glob_match(p.principal_type, p_principal_type)
      AND _glob_match(p.principal_id, p_principal_id)
      AND _glob_match(p.action_type, p_action_type)
      AND _glob_match(p.action_id, p_action_id)
      AND _glob_match(p.resource_type, coalesce(p_resource_type, '*'))
      AND _glob_match(p.resource_id, coalesce(p_resource_id, '*'))
      AND _condition_holds(p.condition, coalesce(p_context, '{}'::jsonb))
      AND _temporal_holds(p_session_id, p.temporal)
    ORDER BY p.priority ASC, p.policy_id ASC
  LOOP
    matched := matched || rec.name;
    IF rec.reason IS NOT NULL THEN
      reasons := reasons || rec.reason;
    END IF;
    obligations := obligations || coalesce(rec.obligations, '[]'::jsonb);

    IF rec.effect = 'forbid' THEN
      has_forbid := true;
    ELSIF rec.effect = 'permit' THEN
      has_permit := true;
    ELSIF rec.effect = 'guide' THEN
      has_guide := true;
    END IF;
  END LOOP;

  -- Deny overrides (Cedar-like): any matching forbid wins over permit
  IF has_forbid THEN
    decision := 'deny';
  ELSIF has_permit THEN
    decision := 'allow';
  ELSIF has_guide THEN
    decision := 'allow';
  END IF;

  effective_mode := mode;

  IF decision = 'deny' THEN
    IF mode = 'log_only' THEN
      decision := 'allow';
      obligations := obligations || jsonb_build_array(
        jsonb_build_object('type', 'shadow_deny', 'value', true)
      );
    ELSIF mode = 'guide' THEN
      decision := 'allow';
      obligations := obligations || jsonb_build_array(
        jsonb_build_object('type', 'would_deny', 'value', true)
      );
    END IF;
  END IF;

  INSERT INTO decision_log(
    session_id, principal_type, principal_id, action_type, action_id,
    resource_type, resource_id, context, decision, matched_policies,
    obligations, reasons, mode
  ) VALUES (
    p_session_id, p_principal_type, p_principal_id, p_action_type, p_action_id,
    p_resource_type, p_resource_id, coalesce(p_context, '{}'::jsonb),
    decision, matched, obligations, reasons, effective_mode
  );

  IF p_session_id IS NOT NULL THEN
    PERFORM record_event(
      p_session_id, p_action_type, p_action_id,
      p_resource_type, p_resource_id, p_context, decision
    );
  END IF;

  IF p_raise_on_deny AND decision = 'deny' AND mode = 'enforce' THEN
    RAISE EXCEPTION 'pg_agent_policy deny: %', coalesce(array_to_string(reasons, '; '), 'forbidden')
      USING ERRCODE = '42501';
  END IF;

  RETURN jsonb_build_object(
    'decision', decision,
    'allowed', decision = 'allow',
    'matched_policies', to_jsonb(matched),
    'obligations', obligations,
    'reasons', to_jsonb(reasons),
    'mode', effective_mode
  );
END;
$$;

COMMENT ON FUNCTION evaluate IS
  'Evaluate agent policy. Returns decision, obligations, reasons, and matched policy names.';

--------------------------------------------------------------------------------
-- Convenience wrappers
--------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION check(
  p_agent text,
  p_tool text,
  p_context jsonb DEFAULT '{}'::jsonb,
  p_session_id text DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql
AS $$
  SELECT (evaluate(
    'agent', p_agent, 'tool', p_tool, '*', '*', p_context, p_session_id, false
  )->>'allowed')::boolean;
$$;

CREATE OR REPLACE FUNCTION enforce(
  p_agent text,
  p_tool text,
  p_context jsonb DEFAULT '{}'::jsonb,
  p_session_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT evaluate(
    'agent', p_agent, 'tool', p_tool, '*', '*', p_context, p_session_id, true
  );
$$;
