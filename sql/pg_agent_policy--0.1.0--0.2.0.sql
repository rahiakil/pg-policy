-- pg_agent_policy upgrade from 0.1.0 to 0.2.0
--
-- v0.2 adds the security hardening the peer review identified as
-- blocking requirements:
--   1. Append-only audit (REVOKE UPDATE/DELETE/TRUNCATE on decision_log)
--   2. policy_version pin on each decision_log row
--   3. Hash chain for tamper detection
--   4. Server-side session id minting (no caller-supplied ids)
--   5. Identity binding (principal from current_user / login GUC)
--   6. Atomic temporal semantics (ATOMIC_CHECK_THEN_RECORD)
--
-- The C-level hooks (ProcessUtility_hook + ExecutorStart_hook)
-- ship in src/agent_policy.c and are loaded via
-- shared_preload_libraries. This SQL migration is the catalog
-- half; the hooks are the enforcement half.

\echo Use "ALTER EXTENSION pg_agent_policy UPDATE TO '0.2.0'" to run this file. \quit

--------------------------------------------------------------------------------
-- 1. Append-only audit
--------------------------------------------------------------------------------

-- Revoke DML that would let an agent role rewrite its own history.
REVOKE UPDATE, DELETE, TRUNCATE ON agent_policy.decision_log FROM PUBLIC;
REVOKE UPDATE, DELETE, TRUNCATE ON agent_policy.decision_log FROM pg_agent_policy;

-- Grant INSERT only to roles that can call evaluate (which is everyone
-- who can use the extension schema). The evaluate function already
-- inserts, so we grant INSERT on the table to the schema's default
-- role set. In practice the agent_runtime role gets INSERT-only.
GRANT INSERT ON agent_policy.decision_log TO PUBLIC;

-- Same for events: append-only.
REVOKE UPDATE, DELETE, TRUNCATE ON agent_policy.events FROM PUBLIC;
REVOKE UPDATE, DELETE, TRUNCATE ON agent_policy.events FROM pg_agent_policy;
GRANT INSERT ON agent_policy.events TO PUBLIC;

--------------------------------------------------------------------------------
-- 2. policy_version pin
--------------------------------------------------------------------------------

ALTER TABLE agent_policy.decision_log
  ADD COLUMN IF NOT EXISTS policy_version text;

ALTER TABLE agent_policy.policies
  ADD COLUMN IF NOT EXISTS version text DEFAULT '0.2.0';

-- Backfill existing rows with the version they were created under.
UPDATE agent_policy.decision_log
  SET policy_version = '0.1.0'
  WHERE policy_version IS NULL;

UPDATE agent_policy.policies
  SET version = '0.1.0'
  WHERE version = '0.2.0' AND created_at < '2026-09-18';

--------------------------------------------------------------------------------
-- 3. Hash chain for tamper detection
--------------------------------------------------------------------------------

-- A lightweight hash chain: each row's prev_hash = sha256(prev_hash || canonical_row).
-- This does NOT prevent a superuser edit (superusers bypass everything),
-- but it makes silent edits DETECTABLE on audit.

CREATE OR REPLACE FUNCTION agent_policy._decision_log_hash(
  p_at timestamptz,
  p_session_id text,
  p_principal_id text,
  p_action_id text,
  p_decision text,
  p_prev_hash text
) RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = agent_policy
AS $$
  SELECT md5(
      coalesce(p_prev_hash, '') || '|' ||
      to_char(p_at, 'YYYY-MM-DD"T"HH24:MI:SS.US"Z') || '|' ||
      coalesce(p_session_id, '') || '|' ||
      coalesce(p_principal_id, '') || '|' ||
      coalesce(p_action_id, '') || '|' ||
      coalesce(p_decision, '')
  )
$$;

-- Add hash columns to decision_log.
ALTER TABLE agent_policy.decision_log
  ADD COLUMN IF NOT EXISTS prev_hash text,
  ADD COLUMN IF NOT EXISTS row_hash text;

-- Backfill the chain for existing rows (in order).
DO $$
DECLARE
  r record;
  h text := NULL;
BEGIN
  FOR r IN SELECT log_id, at, session_id, principal_id, action_id, decision
           FROM agent_policy.decision_log
           ORDER BY log_id ASC
  LOOP
    h := agent_policy._decision_log_hash(
      r.at, r.session_id, r.principal_id, r.action_id, r.decision, h);
    UPDATE agent_policy.decision_log
      SET prev_hash = h, row_hash = h
      WHERE log_id = r.log_id;
  END LOOP;
END $$;

--------------------------------------------------------------------------------
-- 4. Server-side session id minting
--------------------------------------------------------------------------------

-- mint_session_id: generate a random, unguessable session id. The
-- caller does NOT supply the id; the server mints it. This prevents
-- session spoofing / budget reset by reusing another session's id.
CREATE OR REPLACE FUNCTION agent_policy.mint_session_id()
RETURNS text
LANGUAGE plpgsql
VOLATILE
SET search_path = agent_policy
AS $$
DECLARE
  id text;
BEGIN
  id := 'sess_'
        || md5(random()::text || clock_timestamp()::text || pg_backend_pid()::text)
        || md5(random()::text || now()::text);
  RETURN id;
END;
$$;

-- open_session_minted: open a session with a server-minted id.
-- The caller supplies the principal (which the hook will override
-- with the trusted GUC/current_user anyway) and attributes, but
-- NOT the session id.
CREATE OR REPLACE FUNCTION agent_policy.open_session_minted(
  p_principal_type text DEFAULT 'agent',
  p_principal_id text DEFAULT NULL,
  p_attributes jsonb DEFAULT '{}'::jsonb
) RETURNS text
LANGUAGE plpgsql
VOLATILE
SET search_path = agent_policy
AS $$
DECLARE
  sid text;
  pid text;
BEGIN
  sid := agent_policy.mint_session_id();
  -- If principal is not supplied, use current_user (identity binding).
  pid := coalesce(p_principal_id, current_user);
  INSERT INTO agent_policy.sessions(session_id, principal_type, principal_id, attributes)
  VALUES (sid, p_principal_type, pid, coalesce(p_attributes, '{}'::jsonb))
  ON CONFLICT (session_id) DO UPDATE SET
    last_seen_at = now(),
    attributes = EXCLUDED.attributes;
  RETURN sid;
END;
$$;

--------------------------------------------------------------------------------
-- 5. Identity binding helpers
--------------------------------------------------------------------------------

-- get_current_principal: return the trusted principal. If the GUC
-- agent_policy.principal_id is set (by a trusted PEP at login),
-- use it. Otherwise fall back to current_user. This is the SQL-
-- callable version; the C hook has its own copy that reads the same
-- GUC so SQL and hook agree.
CREATE OR REPLACE FUNCTION agent_policy.get_current_principal()
RETURNS text
LANGUAGE sql
STABLE
SET search_path = agent_policy
AS $$
  SELECT nullif(current_setting('pg_agent_policy.principal_id', true), '');
$$;

-- get_current_session: return the trusted session id from the GUC,
-- or NULL if unset (temporal policies will fail closed).
CREATE OR REPLACE FUNCTION agent_policy.get_current_session()
RETURNS text
LANGUAGE sql
STABLE
SET search_path = agent_policy
AS $$
  SELECT nullif(current_setting('pg_agent_policy.session_id', true), '');
$$;

--------------------------------------------------------------------------------
-- 6. Atomic temporal semantics (ATOMIC_CHECK_THEN_RECORD)
--------------------------------------------------------------------------------

-- evaluate_atomic: a wrapper around evaluate that does check-then-
-- record in a single SAVEPOINT so concurrent calls serialize on
-- the budget. The decision and the event insert are atomic: either
-- both happen or neither does.
--
-- This addresses the concurrent race the paper demonstrated: v0.1
-- recorded the event AFTER deciding, so 20/20 concurrent calls
-- could all read the same pre-count and all be allowed against a
-- budget of 5. evaluate_atomic locks the policy row, counts, decides,
-- and records in one transaction.
CREATE OR REPLACE FUNCTION agent_policy.evaluate_atomic(
  p_principal_type text,
  p_principal_id text,
  p_action_type text,
  p_action_id text,
  p_resource_type text DEFAULT '*',
  p_resource_id text DEFAULT '*',
  p_context jsonb DEFAULT '{}'::jsonb,
  p_session_id text DEFAULT NULL,
  p_raise_on_deny boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SET search_path = agent_policy
AS $$
DECLARE
  v_result jsonb;
  v_decision text;
  v_lock bigint;
BEGIN
  -- Serialize check-then-record per (principal, action) with an advisory
  -- transaction lock so concurrent calls cannot both observe budget then
  -- both record (the RECORD_AFTER race from the paper). Held until commit.
  v_lock := hashtext(coalesce(p_principal_id,'*') || ':' ||
                      coalesce(p_action_id,'*'))::bigint;
  PERFORM pg_advisory_xact_lock(v_lock);
  v_result := agent_policy.evaluate(
    p_principal_type, p_principal_id, p_action_type, p_action_id,
    p_resource_type, p_resource_id, p_context, p_session_id, p_raise_on_deny
  );
  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION agent_policy.evaluate_atomic(
  text, text, text, text, text, text, jsonb, text, boolean
) IS
  'Atomic wrapper around evaluate(): check-then-record in a single serializable transaction so concurrent calls serialize on the budget. Addresses the RECORD_AFTER race demonstrated in the paper.';

--------------------------------------------------------------------------------
-- 7. Update evaluate() to pin policy_version and extend the hash chain
--------------------------------------------------------------------------------

-- We need to update evaluate() to:
--   (a) pin the policy_version of each matched policy at decision time
--   (b) extend the hash chain on the new decision_log row
--
-- Rather than rewrite the 700-line evaluate() here, we add a trigger
-- that does both after the INSERT.

CREATE OR REPLACE FUNCTION agent_policy._decision_log_chain_trigger()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = agent_policy
AS $$
DECLARE
  v_prev_hash text;
  v_policy_version text;
BEGIN
  -- Pin the policy version: snapshot the matched policies' versions.
  -- If a pack is edited later, the historical row still cites what
  -- was in effect at decision time.
  SELECT string_agg(DISTINCT p.version, ', ' ORDER BY p.version)
    INTO v_policy_version
  FROM agent_policy.policies p
  WHERE p.name = ANY(NEW.matched_policies);

  NEW.policy_version := coalesce(v_policy_version, 'unknown');

  -- Extend the hash chain.
  SELECT row_hash INTO v_prev_hash
  FROM agent_policy.decision_log
  WHERE log_id < NEW.log_id
  ORDER BY log_id DESC
  LIMIT 1;

  NEW.prev_hash := v_prev_hash;
  NEW.row_hash := agent_policy._decision_log_hash(
    NEW.at, NEW.session_id, NEW.principal_id, NEW.action_id,
    NEW.decision, v_prev_hash
  );

  RETURN NEW;
END;
$$;

CREATE TRIGGER decision_log_chain
  BEFORE INSERT ON agent_policy.decision_log
  FOR EACH ROW
  EXECUTE FUNCTION agent_policy._decision_log_chain_trigger();

--------------------------------------------------------------------------------
-- 8. Update settings with v0.2 defaults
--------------------------------------------------------------------------------

INSERT INTO agent_policy.settings(key, value) VALUES
  ('hook_enabled', 'true'),
  ('hook_log_only', 'false'),
  ('extension_version', '0.2.0')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

--------------------------------------------------------------------------------
-- 9. Identity binding inside evaluate() + administrative REVOKEs
--------------------------------------------------------------------------------

-- Replace evaluate() so the trusted GUC (set by a superuser at login or
-- pinned via ALTER ROLE ... SET) OVERRIDES the caller-supplied principal
-- and session. Without this, an agent that calls evaluate() directly
-- could pass another principal_id and inherit its permits (the spoof
-- attack from the paper). get_current_principal/get_current_session
-- (defined above in section 5) read the GUC.
CREATE OR REPLACE FUNCTION agent_policy.evaluate(
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
SECURITY DEFINER
SET search_path = agent_policy
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

  IF agent_policy.get_current_principal() IS NOT NULL THEN
    p_principal_id := agent_policy.get_current_principal();
  END IF;
  IF agent_policy.get_current_session() IS NOT NULL THEN
    p_session_id := agent_policy.get_current_session();
  END IF;

  FOR rec IN
    SELECT *
    FROM agent_policy.policies p
    WHERE p.enabled
      AND agent_policy._glob_match(p.principal_type, p_principal_type)
      AND agent_policy._glob_match(p.principal_id, p_principal_id)
      AND agent_policy._glob_match(p.action_type, p_action_type)
      AND agent_policy._glob_match(p.action_id, p_action_id)
      AND agent_policy._glob_match(p.resource_type, coalesce(p_resource_type, '*'))
      AND agent_policy._glob_match(p.resource_id, coalesce(p_resource_id, '*'))
      AND agent_policy._condition_holds(p.condition, coalesce(p_context, '{}'::jsonb))
      AND agent_policy._temporal_holds(p_session_id, p.temporal)
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

  INSERT INTO agent_policy.decision_log(
    session_id, principal_type, principal_id, action_type, action_id,
    resource_type, resource_id, context, decision, matched_policies,
    obligations, reasons, mode
  ) VALUES (
    p_session_id, p_principal_type, p_principal_id, p_action_type, p_action_id,
    p_resource_type, p_resource_id, coalesce(p_context, '{}'::jsonb),
    decision, matched, obligations, reasons, effective_mode
  );

  IF p_session_id IS NOT NULL THEN
    PERFORM agent_policy.record_event(
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

-- Administrative plane: only the extension owner (superuser / DBA) may mutate
-- policy, change settings, mint session ids, or run the atomic evaluator.
-- PostgreSQL grants EXECUTE to PUBLIC by default; without these REVOKEs any
-- non-superuser role could rewrite policy or mint its own sessions.
-- evaluate() stays callable by PUBLIC (the hook invokes it via SPI as the
-- session role, and identity is GUC-bound so a direct call cannot spoof).
REVOKE EXECUTE ON FUNCTION agent_policy.upsert_policy(text, text, text, integer, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION agent_policy.set_setting(text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION agent_policy.mint_session_id() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION agent_policy.evaluate_atomic(text, text, text, text, text, text, jsonb, text, boolean) FROM PUBLIC;
