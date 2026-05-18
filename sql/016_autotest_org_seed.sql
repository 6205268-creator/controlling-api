-- 016_autotest_org_seed.sql
-- Организация для автоматизированного тестирования.
-- Данные не загружаются — сценарии тестов создают их сами.

DO $$
DECLARE
    v_org UUID;
BEGIN
    INSERT INTO private.organizations (name, org_type)
    VALUES ('СТ «Авто-тест»', 'gardening')
    RETURNING id INTO v_org;

    INSERT INTO private.users (login, password_hash, full_name, role, organization_id)
    VALUES
        ('autotest_chair',    crypt('autotest123', gen_salt('bf', 10)), 'Председатель Авто-тест', 'admin',     v_org),
        ('autotest_treasury', crypt('autotest123', gen_salt('bf', 10)), 'Казначей Авто-тест',     'treasurer', v_org);
END;
$$;
