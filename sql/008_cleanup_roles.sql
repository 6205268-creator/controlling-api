-- =============================================================================
-- 008_cleanup_roles.sql
-- Канонический набор ролей: superadmin, admin, treasurer
-- Удалены: board, member (как роли пользователя), background
-- ПРИМЕЧАНИЕ: 'member' как тип фин. объекта (plot/member/meter) не затронут
-- =============================================================================

-- 1. Обновить CHECK-ограничение на таблице пользователей
ALTER TABLE private.users DROP CONSTRAINT IF EXISTS users_role_check;
ALTER TABLE private.users ADD CONSTRAINT users_role_check
    CHECK (role = ANY (ARRAY['superadmin', 'admin', 'treasurer']));

-- 2. Пересоздать create_user: убрать устаревший default, добавить явную валидацию
DROP FUNCTION IF EXISTS api.create_user(text, text, text, text, uuid);

CREATE OR REPLACE FUNCTION api.create_user(
    p_login     TEXT,
    p_password  TEXT,
    p_full_name TEXT,
    p_role      TEXT,
    p_org_id    UUID DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_claims      JSONB := current_setting('request.jwt.claims', true)::jsonb;
    v_caller_role TEXT  := v_claims->>'user_role';
    v_org_id      UUID;
    v_new_id      UUID;
BEGIN
    -- Только admin может создавать пользователей
    IF v_caller_role <> 'admin' THEN
        RAISE EXCEPTION 'only admin can create users' USING ERRCODE = '42501';
    END IF;

    -- Допустимые роли для создания (superadmin создать нельзя)
    IF p_role NOT IN ('admin', 'treasurer') THEN
        RAISE EXCEPTION 'INVALID_ROLE: допустимые роли: admin, treasurer'
            USING ERRCODE = 'P0001';
    END IF;

    -- Пользователь создаётся только в своей организации
    v_org_id := (v_claims->>'organization_id')::uuid;

    INSERT INTO private.users (login, password_hash, full_name, role, organization_id)
    VALUES (p_login, crypt(p_password, gen_salt('bf', 10)), p_full_name, p_role, v_org_id)
    RETURNING id INTO v_new_id;

    RETURN jsonb_build_object('user_id', v_new_id, 'login', p_login, 'role', p_role);
END;
$$;

-- 3. Восстановить права (функция пересоздана — нужно выдать заново)
GRANT EXECUTE ON FUNCTION api.create_user(text, text, text, text, uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION api.create_user(text, text, text, text, uuid) FROM anon;
