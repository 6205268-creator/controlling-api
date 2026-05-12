# Право владения участком — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Реализовать полный flow оформления права владения участком: перезапись SQL-миграции 010 + RPC-функции + диалог на фронтенде.

**Architecture:** Standalone-таблица `private.doc_ownership` (не привязана к `private.documents`). `financial_object_registry` превращается в периодический регистр с `valid_from/valid_to`. Строчная блокировка (`FOR UPDATE`) в `post_ownership` вместо UNIQUE-ограничения. Автосоздание члена СТ при проведении документа на физлицо.

**Tech Stack:** PostgreSQL + PostgREST (бэкенд), React 18 + TypeScript + Tailwind + shadcn/ui (фронтенд)

---

## File Map

### Backend
- Modify: `sql/010_ownership_flow.sql` — полная перезапись

### Frontend
- Modify: `src/lib/api.ts` — добавить типы и функции ownership
- Create: `src/components/OwnershipDialog.tsx` — модальный диалог
- Modify: `src/pages/PlotsPage.tsx` — кнопки + подключение диалога

---

## Task 1: Rewrite sql/010_ownership_flow.sql

**Files:**
- Modify: `/home/roman/controlling-backend/sql/010_ownership_flow.sql`

- [ ] **Step 1: Replace the entire file with the new migration**

```sql
-- =============================================================================
-- Migration 010: Ownership document flow (rewrite 2026-05-12)
-- 1.  Wipe test data
-- 2.  contractors: add contractor_type
-- 3.  financial_object_registry: reshape to periodic register (valid_from/valid_to)
-- 4.  Drop plot_ownerships
-- 5.  Create standalone private.doc_ownership
-- 6.  members: add source_doc_id + UNIQUE(organization_id, contractor_id)
-- 7.  Rebuild api.plot_summary using financial_object_registry
-- 8.  Create api.contractors view
-- 9.  RPC: search_contractors
-- 10. RPC: create_contractor (with contractor_type)
-- 11. RPC: create_ownership
-- 12. RPC: post_ownership
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Wipe test data (FK order)
-- ---------------------------------------------------------------------------
DELETE FROM private.meter_readings;
DELETE FROM private.doc_accrual_lines;
DELETE FROM private.doc_distribution_lines;
DELETE FROM private.doc_accrual;
DELETE FROM private.doc_distribution;
DELETE FROM private.doc_payment;
DELETE FROM private.doc_meter_reading;
DELETE FROM private.doc_meter_charge;
DELETE FROM private.doc_period_close;
DELETE FROM private.doc_meter_correction;
DELETE FROM private.debt_movements;
DELETE FROM private.account_movements;
DELETE FROM private.documents;
DELETE FROM private.members;
DELETE FROM private.financial_object_registry;
DELETE FROM private.meters;
UPDATE private.plots SET owner_id = NULL;
DELETE FROM private.contractors;
DELETE FROM private.period_locks;

-- ---------------------------------------------------------------------------
-- 2. contractors: add contractor_type
-- ---------------------------------------------------------------------------
ALTER TABLE private.contractors
    ADD COLUMN IF NOT EXISTS contractor_type VARCHAR(20) NOT NULL DEFAULT 'individual'
        CHECK (contractor_type IN ('individual', 'legal_entity'));

-- ---------------------------------------------------------------------------
-- 3. financial_object_registry: reshape to periodic register
--    owner_id → contractor_id, registered_at → valid_from, drop is_active, add valid_to
-- ---------------------------------------------------------------------------
ALTER TABLE private.financial_object_registry
    DROP CONSTRAINT IF EXISTS financial_object_registry_organization_id_object_type_objec_key;

ALTER TABLE private.financial_object_registry
    DROP CONSTRAINT IF EXISTS financial_object_registry_owner_id_fkey;

ALTER TABLE private.financial_object_registry
    RENAME COLUMN owner_id TO contractor_id;

ALTER TABLE private.financial_object_registry
    RENAME COLUMN registered_at TO valid_from;

ALTER TABLE private.financial_object_registry
    DROP COLUMN IF EXISTS is_active;

ALTER TABLE private.financial_object_registry
    ADD COLUMN IF NOT EXISTS valid_to DATE;

ALTER TABLE private.financial_object_registry
    ADD CONSTRAINT financial_object_registry_contractor_id_fkey
        FOREIGN KEY (contractor_id) REFERENCES private.contractors(id);

-- ---------------------------------------------------------------------------
-- 4. Drop plot_ownerships (replaced by financial_object_registry)
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS private.plot_ownerships CASCADE;

-- ---------------------------------------------------------------------------
-- 5. Create standalone doc_ownership table
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS private.doc_ownership;

CREATE TABLE private.doc_ownership (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID        NOT NULL REFERENCES private.organizations(id),
    contractor_id   UUID        NOT NULL REFERENCES private.contractors(id),
    object_type     VARCHAR(50) NOT NULL DEFAULT 'plot',
    object_id       UUID        NOT NULL,
    doc_date        DATE        NOT NULL DEFAULT CURRENT_DATE,
    notes           TEXT,
    status          VARCHAR(20) NOT NULL DEFAULT 'draft'
                        CHECK (status IN ('draft', 'posted')),
    created_by      UUID,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE private.doc_ownership ENABLE ROW LEVEL SECURITY;

CREATE POLICY org_isolation ON private.doc_ownership
    USING (organization_id = private.current_org_id());

-- ---------------------------------------------------------------------------
-- 6. members: source_doc_id + UNIQUE(organization_id, contractor_id)
-- ---------------------------------------------------------------------------
ALTER TABLE private.members
    ADD COLUMN IF NOT EXISTS source_doc_id UUID REFERENCES private.doc_ownership(id);

ALTER TABLE private.members
    DROP CONSTRAINT IF EXISTS members_organization_id_contractor_id_key;

ALTER TABLE private.members
    ADD CONSTRAINT members_organization_id_contractor_id_key
        UNIQUE (organization_id, contractor_id);

-- ---------------------------------------------------------------------------
-- 7. Rebuild api.plot_summary — owner from financial_object_registry
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api.plot_summary;

CREATE VIEW api.plot_summary AS
SELECT
    p.id,
    p.organization_id,
    p.number,
    p.area,
    p.is_active,
    r.contractor_id AS owner_id,
    c.full_name     AS owner_name,
    c.phone         AS owner_phone,
    COALESCE(d.total_debt, 0) AS total_debt
FROM private.plots p
LEFT JOIN private.financial_object_registry r
    ON  r.organization_id = p.organization_id
    AND r.object_type     = 'plot'
    AND r.object_id       = p.id
    AND r.valid_to IS NULL
LEFT JOIN private.contractors c ON c.id = r.contractor_id
LEFT JOIN (
    SELECT object_id, SUM(amount) AS total_debt
    FROM private.debt_movements
    WHERE object_type = 'plot'
    GROUP BY object_id
) d ON d.object_id = p.id;

GRANT SELECT ON api.plot_summary TO authenticated;

-- ---------------------------------------------------------------------------
-- 8. api.contractors view
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api.contractors;

CREATE VIEW api.contractors AS
SELECT id, organization_id, full_name, contractor_type, phone, email, address, is_active, created_at
FROM private.contractors;

GRANT SELECT ON api.contractors TO authenticated;
REVOKE SELECT ON api.contractors FROM anon;

-- ---------------------------------------------------------------------------
-- 9. RPC: search_contractors
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.search_contractors(p_org_id UUID, p_query TEXT DEFAULT '')
RETURNS TABLE(id UUID, full_name TEXT, contractor_type VARCHAR, phone TEXT)
LANGUAGE sql SECURITY DEFINER STABLE AS $$
    SELECT c.id, c.full_name, c.contractor_type, c.phone
    FROM private.contractors c
    WHERE c.organization_id = p_org_id
      AND c.is_active = true
      AND (
          trim(p_query) = '' OR
          c.full_name ILIKE '%' || trim(p_query) || '%' OR
          c.phone     ILIKE '%' || trim(p_query) || '%'
      )
    ORDER BY c.full_name
    LIMIT 20;
$$;

GRANT EXECUTE ON FUNCTION api.search_contractors(UUID, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- 10. RPC: create_contractor (with contractor_type)
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api.create_contractor(UUID, TEXT, TEXT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION api.create_contractor(
    p_org_id          UUID,
    p_full_name       TEXT,
    p_contractor_type VARCHAR DEFAULT 'individual',
    p_phone           TEXT    DEFAULT NULL,
    p_email           TEXT    DEFAULT NULL,
    p_address         TEXT    DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_id UUID;
BEGIN
    IF p_full_name IS NULL OR trim(p_full_name) = '' THEN
        RAISE EXCEPTION 'INVALID_NAME: ФИО не может быть пустым';
    END IF;
    IF p_contractor_type NOT IN ('individual', 'legal_entity') THEN
        RAISE EXCEPTION 'INVALID_TYPE: contractor_type must be individual or legal_entity';
    END IF;

    INSERT INTO private.contractors (
        organization_id, full_name, contractor_type, phone, email, address
    ) VALUES (
        p_org_id, trim(p_full_name), p_contractor_type,
        nullif(trim(p_phone),   ''),
        nullif(trim(p_email),   ''),
        nullif(trim(p_address), '')
    )
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('ok', true, 'contractor_id', v_id);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_contractor(UUID, TEXT, VARCHAR, TEXT, TEXT, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- 11. RPC: create_ownership — creates draft document
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.create_ownership(
    p_org_id        UUID,
    p_contractor_id UUID,
    p_object_type   VARCHAR DEFAULT 'plot',
    p_object_id     UUID,
    p_doc_date      DATE    DEFAULT CURRENT_DATE,
    p_notes         TEXT    DEFAULT NULL,
    p_created_by    UUID    DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_doc_id UUID;
BEGIN
    INSERT INTO private.doc_ownership (
        organization_id, contractor_id, object_type, object_id,
        doc_date, notes, status, created_by
    ) VALUES (
        p_org_id, p_contractor_id, p_object_type, p_object_id,
        p_doc_date, p_notes, 'draft', p_created_by
    )
    RETURNING id INTO v_doc_id;

    RETURN jsonb_build_object('ok', true, 'doc_id', v_doc_id, 'status', 'draft');
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_ownership(UUID, UUID, VARCHAR, UUID, DATE, TEXT, UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- 12. RPC: post_ownership — posts document in transaction with row lock
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.post_ownership(p_doc_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_doc             private.doc_ownership%ROWTYPE;
    v_contractor_type VARCHAR(20);
    v_max_num         INT;
BEGIN
    -- Row lock prevents two concurrent posts on same document
    SELECT * INTO v_doc
    FROM private.doc_ownership
    WHERE id = p_doc_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'DOC_NOT_FOUND: документ % не найден', p_doc_id;
    END IF;
    IF v_doc.status = 'posted' THEN
        RAISE EXCEPTION 'ALREADY_POSTED: документ уже проведён';
    END IF;

    SELECT contractor_type INTO v_contractor_type
    FROM private.contractors
    WHERE id = v_doc.contractor_id;

    -- Close current registry record for this object (if any)
    UPDATE private.financial_object_registry
    SET valid_to = v_doc.doc_date - 1
    WHERE organization_id = v_doc.organization_id
      AND object_type     = v_doc.object_type::private.fin_object_type
      AND object_id       = v_doc.object_id
      AND valid_to IS NULL;

    -- Insert new registry record (current owner)
    INSERT INTO private.financial_object_registry (
        organization_id, object_type, object_id, contractor_id, valid_from
    ) VALUES (
        v_doc.organization_id,
        v_doc.object_type::private.fin_object_type,
        v_doc.object_id,
        v_doc.contractor_id,
        v_doc.doc_date
    );

    -- Auto-create ST member for individuals without existing membership
    IF v_contractor_type = 'individual' AND NOT EXISTS (
        SELECT 1 FROM private.members
        WHERE organization_id = v_doc.organization_id
          AND contractor_id   = v_doc.contractor_id
    ) THEN
        SELECT COALESCE(
            MAX(member_number::int) FILTER (WHERE member_number ~ '^\d+$'), 0
        ) INTO v_max_num
        FROM private.members
        WHERE organization_id = v_doc.organization_id;

        INSERT INTO private.members (
            organization_id, contractor_id, member_number, joined_at, source_doc_id
        ) VALUES (
            v_doc.organization_id,
            v_doc.contractor_id,
            (v_max_num + 1)::text,
            v_doc.doc_date,
            p_doc_id
        );
    END IF;

    UPDATE private.doc_ownership SET status = 'posted' WHERE id = p_doc_id;

    RETURN jsonb_build_object(
        'ok',            true,
        'doc_id',        p_doc_id,
        'object_type',   v_doc.object_type,
        'object_id',     v_doc.object_id,
        'contractor_id', v_doc.contractor_id
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.post_ownership(UUID) TO authenticated;
```

- [ ] **Step 2: Commit**

```bash
cd /home/roman/controlling-backend
git add sql/010_ownership_flow.sql
git commit -m "feat: rewrite 010 — standalone doc_ownership, periodic registry, contractor_type"
```

---

## Task 2: Apply migration 010 and verify

**Files:** нет (только операции с БД)

- [ ] **Step 1: Apply migration**

```bash
cat /home/roman/controlling-backend/sql/010_ownership_flow.sql | sudo -u postgres psql -d controlling
```

Expected: последовательность `ALTER TABLE`, `DROP TABLE`, `CREATE TABLE`, `CREATE FUNCTION` — без ошибок.

- [ ] **Step 2: Verify table structures**

```bash
sudo -u postgres psql -d controlling -c "\d private.contractors" | grep contractor_type
```
Expected: `contractor_type | character varying(20) | not null | 'individual'`

```bash
sudo -u postgres psql -d controlling -c "\d private.financial_object_registry"
```
Expected: колонки `valid_from date`, `valid_to date`, `contractor_id uuid`. Колонок `is_active` и `owner_id` нет. UNIQUE-constraint на (org, object_type, object_id) отсутствует.

```bash
sudo -u postgres psql -d controlling -c "\d private.doc_ownership"
```
Expected: таблица с колонками id, organization_id, contractor_id, object_type, object_id, doc_date, notes, status, created_by, created_at.

```bash
sudo -u postgres psql -d controlling -c "SELECT EXISTS(SELECT 1 FROM pg_tables WHERE schemaname='private' AND tablename='plot_ownerships');"
```
Expected: `f` (таблица удалена).

```bash
sudo -u postgres psql -d controlling -c "\d private.members" | grep source_doc_id
```
Expected: `source_doc_id | uuid`

- [ ] **Step 3: Verify RPC end-to-end in a transaction**

```bash
sudo -u postgres psql -d controlling << 'ENDSQL'
-- Используем superadmin сессию напрямую через private схему
DO $$
DECLARE
  v_org_id      UUID;
  v_plot_id     UUID;
  v_ctr_result  JSONB;
  v_ctr_id      UUID;
  v_doc_result  JSONB;
  v_doc_id      UUID;
  v_post_result JSONB;
  v_member_cnt  INT;
BEGIN
  SELECT id INTO v_org_id FROM private.organizations LIMIT 1;
  SELECT id INTO v_plot_id FROM private.plots WHERE organization_id = v_org_id LIMIT 1;

  -- create contractor
  SELECT api.create_contractor(v_org_id, 'Тестовый Иванов', 'individual', '+7 900 111 22 33')
  INTO v_ctr_result;
  ASSERT (v_ctr_result->>'ok')::boolean, 'create_contractor failed: ' || v_ctr_result::text;
  v_ctr_id := (v_ctr_result->>'contractor_id')::UUID;

  -- create ownership doc
  SELECT api.create_ownership(v_org_id, v_ctr_id, 'plot', v_plot_id, CURRENT_DATE, NULL, NULL)
  INTO v_doc_result;
  ASSERT (v_doc_result->>'ok')::boolean, 'create_ownership failed: ' || v_doc_result::text;
  v_doc_id := (v_doc_result->>'doc_id')::UUID;

  -- post ownership
  SELECT api.post_ownership(v_doc_id) INTO v_post_result;
  ASSERT (v_post_result->>'ok')::boolean, 'post_ownership failed: ' || v_post_result::text;

  -- verify registry
  ASSERT EXISTS (
    SELECT 1 FROM private.financial_object_registry
    WHERE object_id = v_plot_id AND contractor_id = v_ctr_id AND valid_to IS NULL
  ), 'Registry record not found';

  -- verify member auto-created
  SELECT COUNT(*) INTO v_member_cnt
  FROM private.members WHERE organization_id = v_org_id AND contractor_id = v_ctr_id;
  ASSERT v_member_cnt = 1, 'Member not auto-created, count: ' || v_member_cnt;

  -- verify no second member on repeat post attempt
  SELECT api.post_ownership(v_doc_id) INTO v_post_result;
  ASSERT NOT (v_post_result->>'ok')::boolean, 'Repeated post should fail';

  RAISE NOTICE 'All assertions passed';
  ROLLBACK; -- clean up test data
END;
$$;
ENDSQL
```

Expected: `NOTICE: All assertions passed` — без ошибок assert.

---

## Task 3: Frontend — ownership API functions

**Files:**
- Modify: `/home/roman/controlling-frontend/src/lib/api.ts`
- Test: `/home/roman/controlling-frontend/src/lib/__tests__/ownership-api.test.ts`

- [ ] **Step 1: Add types and functions at the end of src/lib/api.ts**

Дописать в конец файла `src/lib/api.ts`:

```typescript
// --- Ownership ---

export interface Contractor {
  id: string
  full_name: string
  contractor_type: 'individual' | 'legal_entity'
  phone: string | null
}

export interface RpcResult {
  ok: boolean
  error?: string
  [key: string]: unknown
}

export async function searchContractors(orgId: string, query: string): Promise<Contractor[]> {
  return apiFetch<Contractor[]>('/rpc/search_contractors', {
    method: 'POST',
    body: JSON.stringify({ p_org_id: orgId, p_query: query }),
  })
}

export async function createContractor(params: {
  orgId: string
  fullName: string
  contractorType: 'individual' | 'legal_entity'
  phone?: string
}): Promise<RpcResult> {
  return apiFetch<RpcResult>('/rpc/create_contractor', {
    method: 'POST',
    body: JSON.stringify({
      p_org_id:          params.orgId,
      p_full_name:       params.fullName,
      p_contractor_type: params.contractorType,
      p_phone:           params.phone ?? null,
    }),
  })
}

export async function createOwnership(params: {
  orgId: string
  contractorId: string
  objectType: string
  objectId: string
  docDate: string
  notes?: string
}): Promise<RpcResult> {
  return apiFetch<RpcResult>('/rpc/create_ownership', {
    method: 'POST',
    body: JSON.stringify({
      p_org_id:        params.orgId,
      p_contractor_id: params.contractorId,
      p_object_type:   params.objectType,
      p_object_id:     params.objectId,
      p_doc_date:      params.docDate,
      p_notes:         params.notes ?? null,
    }),
  })
}

export async function postOwnership(docId: string): Promise<RpcResult> {
  return apiFetch<RpcResult>('/rpc/post_ownership', {
    method: 'POST',
    body: JSON.stringify({ p_doc_id: docId }),
  })
}
```

- [ ] **Step 2: Write tests**

Создать `src/lib/__tests__/ownership-api.test.ts`:

```typescript
import { describe, it, expect, vi, beforeEach } from 'vitest'

const mockFetch = vi.fn()
global.fetch = mockFetch

vi.mock('../auth', () => ({
  getToken: () => 'test-token',
  getOrgId: () => 'org-123',
  logout: vi.fn(),
}))

import { searchContractors, createContractor, createOwnership, postOwnership } from '../api'

function okJson(data: unknown) {
  return Promise.resolve({ ok: true, status: 200, json: async () => data })
}

beforeEach(() => mockFetch.mockReset())

describe('searchContractors', () => {
  it('posts to /rpc/search_contractors and returns array', async () => {
    const rows = [{ id: 'c-1', full_name: 'Иванов', contractor_type: 'individual', phone: null }]
    mockFetch.mockResolvedValueOnce(okJson(rows))

    const result = await searchContractors('org-1', 'Иванов')

    expect(result).toEqual(rows)
    expect(mockFetch).toHaveBeenCalledWith(
      expect.stringContaining('/rpc/search_contractors'),
      expect.objectContaining({ method: 'POST' })
    )
  })
})

describe('createContractor', () => {
  it('returns ok:true with contractor_id', async () => {
    mockFetch.mockResolvedValueOnce(okJson({ ok: true, contractor_id: 'c-new' }))

    const result = await createContractor({
      orgId: 'org-1', fullName: 'Петров', contractorType: 'individual', phone: '+7 900 000 00 01',
    })

    expect(result.ok).toBe(true)
    expect(result.contractor_id).toBe('c-new')
  })
})

describe('createOwnership', () => {
  it('returns ok:true with doc_id', async () => {
    mockFetch.mockResolvedValueOnce(okJson({ ok: true, doc_id: 'doc-1', status: 'draft' }))

    const result = await createOwnership({
      orgId: 'org-1', contractorId: 'c-1', objectType: 'plot',
      objectId: 'plot-1', docDate: '2026-05-12',
    })

    expect(result.ok).toBe(true)
    expect(result.doc_id).toBe('doc-1')
  })
})

describe('postOwnership', () => {
  it('returns ok:true on success', async () => {
    mockFetch.mockResolvedValueOnce(okJson({ ok: true, doc_id: 'doc-1' }))
    const result = await postOwnership('doc-1')
    expect(result.ok).toBe(true)
  })

  it('returns ok:false when already posted', async () => {
    mockFetch.mockResolvedValueOnce(okJson({ ok: false, error: 'ALREADY_POSTED: документ уже проведён' }))
    const result = await postOwnership('doc-1')
    expect(result.ok).toBe(false)
    expect(result.error).toContain('ALREADY_POSTED')
  })
})
```

- [ ] **Step 3: Run tests**

```bash
cd /home/roman/controlling-frontend && npx vitest run src/lib/__tests__/ownership-api.test.ts
```

Expected: 4/4 PASS.

- [ ] **Step 4: Commit**

```bash
cd /home/roman/controlling-frontend
git add src/lib/api.ts src/lib/__tests__/ownership-api.test.ts
git commit -m "feat: add ownership API functions (searchContractors, createContractor, createOwnership, postOwnership)"
```

---

## Task 4: Frontend — OwnershipDialog component

**Files:**
- Create: `/home/roman/controlling-frontend/src/components/OwnershipDialog.tsx`

- [ ] **Step 1: Create the component**

Создать `src/components/OwnershipDialog.tsx`:

```tsx
import { useEffect, useRef, useState } from 'react'
import { getOrgId } from '../lib/auth'
import {
  searchContractors,
  createContractor,
  createOwnership,
  postOwnership,
  type Contractor,
} from '../lib/api'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'

export interface PlotOption {
  id: string
  number: string
  owner_name: string | null
}

interface Props {
  open: boolean
  onClose: () => void
  onPosted: () => void
  preselectedPlot: PlotOption | null
  allPlots: PlotOption[]
}

export default function OwnershipDialog({ open, onClose, onPosted, preselectedPlot, allPlots }: Props) {
  const orgId = getOrgId() ?? ''

  const [selectedPlot, setSelectedPlot] = useState<PlotOption | null>(null)
  const [contractorMode, setContractorMode] = useState<'search' | 'create'>('search')
  const [query, setQuery] = useState('')
  const [suggestions, setSuggestions] = useState<Contractor[]>([])
  const [selectedContractor, setSelectedContractor] = useState<Contractor | null>(null)
  const [newName, setNewName] = useState('')
  const [newType, setNewType] = useState<'individual' | 'legal_entity'>('individual')
  const [newPhone, setNewPhone] = useState('')
  const [docDate, setDocDate] = useState(new Date().toISOString().slice(0, 10))
  const [notes, setNotes] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [success, setSuccess] = useState(false)
  const searchTimer = useRef<ReturnType<typeof setTimeout> | null>(null)

  useEffect(() => {
    if (open) setSelectedPlot(preselectedPlot)
  }, [open, preselectedPlot])

  useEffect(() => {
    if (contractorMode !== 'search' || query.trim().length < 2) { setSuggestions([]); return }
    if (searchTimer.current) clearTimeout(searchTimer.current)
    searchTimer.current = setTimeout(async () => {
      try { setSuggestions(await searchContractors(orgId, query)) } catch { setSuggestions([]) }
    }, 300)
  }, [query, contractorMode, orgId])

  function reset() {
    setSelectedPlot(preselectedPlot)
    setContractorMode('search')
    setQuery('')
    setSuggestions([])
    setSelectedContractor(null)
    setNewName('')
    setNewType('individual')
    setNewPhone('')
    setDocDate(new Date().toISOString().slice(0, 10))
    setNotes('')
    setError(null)
    setSuccess(false)
  }

  function handleClose() { reset(); onClose() }

  async function handleSubmit() {
    if (!selectedPlot) { setError('Выберите участок'); return }
    setSubmitting(true)
    setError(null)
    try {
      let contractorId: string | null = selectedContractor?.id ?? null

      if (contractorMode === 'create') {
        if (!newName.trim()) { setError('Введите ФИО или название'); return }
        const cr = await createContractor({ orgId, fullName: newName, contractorType: newType, phone: newPhone || undefined })
        if (!cr.ok) { setError(cr.error ?? 'Ошибка создания контрагента'); return }
        contractorId = cr.contractor_id as string
      }

      if (!contractorId) { setError('Выберите или создайте владельца'); return }

      const doc = await createOwnership({
        orgId, contractorId, objectType: 'plot', objectId: selectedPlot.id, docDate, notes: notes || undefined,
      })
      if (!doc.ok) { setError(doc.error ?? 'Ошибка создания документа'); return }

      const posted = await postOwnership(doc.doc_id as string)
      if (!posted.ok) { setError(posted.error ?? 'Ошибка проведения'); return }

      setSuccess(true)
      setTimeout(() => { reset(); onPosted(); onClose() }, 1200)
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Неизвестная ошибка')
    } finally {
      setSubmitting(false)
    }
  }

  if (!open) return null

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40" onClick={e => { if (e.target === e.currentTarget) handleClose() }}>
      <div className="bg-white rounded-xl shadow-xl w-full max-w-lg p-6 space-y-4">
        <div className="flex items-center justify-between">
          <h2 className="text-lg font-semibold text-zinc-900">Оформить право владения</h2>
          <button onClick={handleClose} className="text-zinc-400 hover:text-zinc-600 text-xl leading-none">&times;</button>
        </div>

        {/* Блок 1 — Участок */}
        <div className="space-y-1.5">
          <label className="text-sm font-medium text-zinc-700">Участок</label>
          <select
            className="w-full border border-zinc-200 rounded-md px-3 py-2 text-sm bg-white text-zinc-900"
            value={selectedPlot?.id ?? ''}
            onChange={e => setSelectedPlot(allPlots.find(p => p.id === e.target.value) ?? null)}
          >
            <option value="">— выберите —</option>
            {allPlots.map(p => (
              <option key={p.id} value={p.id}>
                №{p.number}{p.owner_name ? ` (${p.owner_name})` : ''}
              </option>
            ))}
          </select>
          {selectedPlot?.owner_name && (
            <p className="text-amber-700 text-xs bg-amber-50 border border-amber-200 rounded px-3 py-2">
              Участок уже закреплён за {selectedPlot.owner_name}. Продолжить — переоформить владение.
            </p>
          )}
        </div>

        {/* Блок 2 — Владелец */}
        <div className="space-y-1.5">
          <label className="text-sm font-medium text-zinc-700">Владелец</label>

          {contractorMode === 'search' && (
            <>
              {selectedContractor ? (
                <div className="flex items-center gap-2 border border-zinc-200 rounded-md px-3 py-2 bg-zinc-50">
                  <span className="text-sm text-zinc-900 flex-1">{selectedContractor.full_name}</span>
                  <button className="text-zinc-400 hover:text-zinc-600 text-xs" onClick={() => { setSelectedContractor(null); setQuery('') }}>✕</button>
                </div>
              ) : (
                <div className="space-y-1">
                  <Input placeholder="Поиск по ФИО или телефону..." value={query} onChange={e => setQuery(e.target.value)} />
                  {suggestions.length > 0 && (
                    <div className="border border-zinc-200 rounded-md divide-y divide-zinc-100 max-h-36 overflow-y-auto">
                      {suggestions.map(c => (
                        <button key={c.id} className="w-full text-left px-3 py-2 text-sm hover:bg-zinc-50" onClick={() => { setSelectedContractor(c); setSuggestions([]) }}>
                          <span className="font-medium">{c.full_name}</span>
                          {c.phone && <span className="text-zinc-400 ml-2">{c.phone}</span>}
                        </button>
                      ))}
                    </div>
                  )}
                  <button className="text-sm text-blue-600 hover:underline" onClick={() => setContractorMode('create')}>
                    + Создать нового
                  </button>
                </div>
              )}
            </>
          )}

          {contractorMode === 'create' && (
            <div className="space-y-2 border border-zinc-200 rounded-md p-3">
              <div className="flex gap-2">
                {(['individual', 'legal_entity'] as const).map(type => (
                  <button
                    key={type}
                    className={`flex-1 text-sm py-1.5 rounded border transition-colors ${newType === type ? 'bg-zinc-900 text-white border-zinc-900' : 'border-zinc-200 text-zinc-600 hover:border-zinc-400'}`}
                    onClick={() => setNewType(type)}
                  >
                    {type === 'individual' ? 'Физлицо' : 'Юрлицо'}
                  </button>
                ))}
              </div>
              <Input
                placeholder={newType === 'individual' ? 'ФИО' : 'Название организации'}
                value={newName}
                onChange={e => setNewName(e.target.value)}
              />
              <Input placeholder="Телефон" value={newPhone} onChange={e => setNewPhone(e.target.value)} />
              <button className="text-sm text-zinc-400 hover:text-zinc-600" onClick={() => setContractorMode('search')}>
                ← Найти существующего
              </button>
            </div>
          )}
        </div>

        {/* Блок 3 — Дата и заметки */}
        <div className="grid grid-cols-2 gap-3">
          <div className="space-y-1.5">
            <label className="text-sm font-medium text-zinc-700">Дата документа</label>
            <Input type="date" value={docDate} onChange={e => setDocDate(e.target.value)} />
          </div>
          <div className="space-y-1.5">
            <label className="text-sm font-medium text-zinc-700">Заметки</label>
            <Input placeholder="Необязательно" value={notes} onChange={e => setNotes(e.target.value)} />
          </div>
        </div>

        {error && <p className="text-red-600 text-sm bg-red-50 border border-red-200 rounded px-3 py-2">{error}</p>}
        {success && <p className="text-green-700 text-sm bg-green-50 border border-green-200 rounded px-3 py-2">Право владения оформлено</p>}

        <div className="flex gap-3 pt-1">
          <Button variant="outline" onClick={handleClose} className="flex-1" disabled={submitting}>Отмена</Button>
          <Button onClick={handleSubmit} className="flex-1" disabled={submitting || success}>
            {submitting ? 'Проводим...' : 'Провести документ'}
          </Button>
        </div>
      </div>
    </div>
  )
}
```

- [ ] **Step 2: TypeScript check**

```bash
cd /home/roman/controlling-frontend && npx tsc --noEmit 2>&1 | head -40
```

Expected: ошибок нет (или только ранее существовавшие не в новых файлах).

- [ ] **Step 3: Commit**

```bash
cd /home/roman/controlling-frontend
git add src/components/OwnershipDialog.tsx
git commit -m "feat: add OwnershipDialog — 3-block modal for ownership assignment"
```

---

## Task 5: Frontend — Update PlotsPage

**Files:**
- Modify: `/home/roman/controlling-frontend/src/pages/PlotsPage.tsx`

- [ ] **Step 1: Replace PlotsPage.tsx**

```tsx
import { useEffect, useState } from 'react'
import { apiFetch, orgParam } from '../lib/api'
import { Input } from '@/components/ui/input'
import { Button } from '@/components/ui/button'
import OwnershipDialog, { type PlotOption } from '../components/OwnershipDialog'

interface PlotSummary {
  id: string
  number: string
  area: number
  is_active: boolean
  owner_id: string | null
  owner_name: string | null
  owner_phone: string | null
}

type FilterTab = 'all' | 'active' | 'inactive'

export default function PlotsPage() {
  const [plots, setPlots] = useState<PlotSummary[]>([])
  const [search, setSearch] = useState('')
  const [tab, setTab] = useState<FilterTab>('all')
  const [loading, setLoading] = useState(true)
  const [dialogOpen, setDialogOpen] = useState(false)
  const [preselectedPlot, setPreselectedPlot] = useState<PlotOption | null>(null)

  function loadPlots() {
    setLoading(true)
    apiFetch<PlotSummary[]>(`/plot_summary?${orgParam()}&order=number.asc`)
      .then(setPlots)
      .finally(() => setLoading(false))
  }

  useEffect(() => { loadPlots() }, [])

  function openForAll() { setPreselectedPlot(null); setDialogOpen(true) }
  function openForPlot(p: PlotSummary) {
    setPreselectedPlot({ id: p.id, number: p.number, owner_name: p.owner_name })
    setDialogOpen(true)
  }

  const filtered = plots
    .filter(p => tab === 'all' ? true : tab === 'active' ? p.is_active : !p.is_active)
    .filter(p => !search || (p.owner_name ?? '').toLowerCase().includes(search.toLowerCase()) || p.number.includes(search))

  const counts = { all: plots.length, active: plots.filter(p => p.is_active).length, inactive: plots.filter(p => !p.is_active).length }

  const tabs: { key: FilterTab; label: string }[] = [
    { key: 'all',      label: `Все (${counts.all})` },
    { key: 'active',   label: `Активные (${counts.active})` },
    { key: 'inactive', label: `Неактивные (${counts.inactive})` },
  ]

  const allPlots: PlotOption[] = plots.map(p => ({ id: p.id, number: p.number, owner_name: p.owner_name }))

  if (loading) return <p className="text-zinc-400 text-sm">Загрузка...</p>

  return (
    <div>
      <div className="flex items-center gap-4 mb-5">
        <div className="flex gap-1 bg-white border border-zinc-200 rounded-lg p-1">
          {tabs.map(t => (
            <button
              key={t.key}
              onClick={() => setTab(t.key)}
              className={`px-4 py-1.5 rounded-md text-sm transition-colors ${tab === t.key ? 'bg-zinc-900 text-white font-medium' : 'text-zinc-500 hover:text-zinc-700'}`}
            >
              {t.label}
            </button>
          ))}
        </div>
        <Input
          placeholder="Поиск по владельцу или номеру..."
          value={search}
          onChange={e => setSearch(e.target.value)}
          className="max-w-xs"
        />
        <Button onClick={openForAll} className="ml-auto">
          + Оформить владение
        </Button>
      </div>

      <div className="bg-white rounded-lg border border-zinc-200">
        <table className="w-full text-sm">
          <thead>
            <tr className="bg-zinc-50">
              <th className="text-left px-5 py-2.5 text-xs text-zinc-400 font-medium uppercase tracking-wide">№</th>
              <th className="text-left px-5 py-2.5 text-xs text-zinc-400 font-medium uppercase tracking-wide">Площадь</th>
              <th className="text-left px-5 py-2.5 text-xs text-zinc-400 font-medium uppercase tracking-wide">Владелец</th>
              <th className="text-left px-5 py-2.5 text-xs text-zinc-400 font-medium uppercase tracking-wide">Телефон</th>
              <th className="text-left px-5 py-2.5 text-xs text-zinc-400 font-medium uppercase tracking-wide">Статус</th>
              <th className="px-5 py-2.5"></th>
            </tr>
          </thead>
          <tbody>
            {filtered.map((p, i) => (
              <tr key={p.id} className={i % 2 === 0 ? 'bg-white' : 'bg-zinc-50/60'}>
                <td className="px-5 py-3 font-semibold text-zinc-900">{p.number}</td>
                <td className="px-5 py-3 text-zinc-600">{p.area.toFixed(2)} сот.</td>
                <td className="px-5 py-3 text-zinc-700">{p.owner_name ?? '—'}</td>
                <td className="px-5 py-3 text-zinc-600">{p.owner_phone ?? '—'}</td>
                <td className="px-5 py-3">
                  <span className={`text-xs px-2 py-0.5 rounded-full font-medium ${p.is_active ? 'bg-green-100 text-green-700' : 'bg-zinc-100 text-zinc-500'}`}>
                    {p.is_active ? 'Активен' : 'Неактивен'}
                  </span>
                </td>
                <td className="px-5 py-3 text-right">
                  {!p.owner_id && (
                    <button className="text-xs text-blue-600 hover:underline whitespace-nowrap" onClick={() => openForPlot(p)}>
                      Назначить владельца
                    </button>
                  )}
                </td>
              </tr>
            ))}
            {filtered.length === 0 && (
              <tr><td colSpan={6} className="px-5 py-8 text-center text-zinc-400">Ничего не найдено</td></tr>
            )}
          </tbody>
        </table>
      </div>

      <OwnershipDialog
        open={dialogOpen}
        onClose={() => setDialogOpen(false)}
        onPosted={loadPlots}
        preselectedPlot={preselectedPlot}
        allPlots={allPlots}
      />
    </div>
  )
}
```

- [ ] **Step 2: TypeScript check**

```bash
cd /home/roman/controlling-frontend && npx tsc --noEmit 2>&1 | head -40
```

Expected: ошибок нет.

- [ ] **Step 3: Rebuild and smoke test**

```bash
cd /home/roman/controlling-frontend && docker compose build && docker compose up -d
```

Открыть http://103.35.190.117:3000, войти как `demo_a_chair` / `chair123`:
- Страница «Участки» — кнопка «+ Оформить владение» в правом углу шапки
- На строках без владельца — ссылка «Назначить владельца»
- Кликнуть «Назначить владельца» → диалог открывается с предвыбранным участком
- Поиск контрагента → пустой (все удалены миграцией) → «Создать нового»
- Заполнить ФИО, тип «Физлицо», нажать «Провести документ»
- «Право владения оформлено» → диалог закрывается → участок показывает владельца
- Убедиться что «Назначить владельца» исчезла у этого участка

- [ ] **Step 4: Commit**

```bash
cd /home/roman/controlling-frontend
git add src/pages/PlotsPage.tsx
git commit -m "feat: ownership buttons and dialog on PlotsPage"
```

---

## Self-Review

### Покрытие спека

| Требование | Задача |
|---|---|
| `financial_object_registry` → периодический регистр (valid_from/valid_to) | Task 1 |
| Удалить UNIQUE на (org, object_type, object_id) | Task 1 |
| `plot_ownerships` → DROP | Task 1 |
| `contractors` + `contractor_type` | Task 1 |
| `members` + `source_doc_id` + UNIQUE(org, contractor) | Task 1 |
| `doc_ownership` standalone table | Task 1 |
| `search_contractors` RPC | Task 1 |
| `create_contractor` RPC с contractor_type | Task 1 |
| `create_ownership` RPC → статус draft | Task 1 |
| `post_ownership` RPC с блокировкой строки | Task 1 |
| `api.plot_summary` использует registry | Task 1 |
| `api.contractors` view | Task 1 |
| Frontend: кнопка «+ Оформить владение» в шапке | Task 5 |
| Frontend: «Назначить владельца» на строке без owner | Task 5 |
| Frontend: Блок 1 — выбор участка + предвыбор | Task 4 |
| Frontend: Блок 2 — живой поиск + создание нового | Task 4 |
| Frontend: Блок 3 — дата + заметки + кнопка провести | Task 4 |
| Frontend: предупреждение если участок уже имеет владельца | Task 4 |
| Frontend: список обновляется после проведения | Task 5 (onPosted → loadPlots) |
| Юрлицо — член СТ не создаётся | Task 1 (проверка contractor_type) |
| Дублирование членства: NOT EXISTS + UNIQUE | Task 1 |
| Строчная блокировка (не UNIQUE, не конкурент) | Task 1 (FOR UPDATE) |
| Отмены нет — append-only | Task 1 (post_ownership только дописывает) |

### Placeholder scan
Нет TBD, TODO, «аналогично», «обработай ошибки» без кода.

### Type consistency
- `PlotOption` экспортируется из `OwnershipDialog.tsx` → импортируется в `PlotsPage.tsx` ✅
- `Contractor` из `api.ts` → используется в `OwnershipDialog.tsx` ✅
- `RpcResult.ok: boolean` → все проверки `if (!result.ok)` ✅
- `doc.doc_id as string` — `RpcResult` имеет `[key: string]: unknown`, приведение явное ✅
- `postOwnership(docId: string)` → `p_doc_id` UUID на бэке — PostgREST принимает строку ✅
