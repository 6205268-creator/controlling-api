-- 014_current_ownership.sql
-- View: current owner of any object (plot, meter, etc.)
-- Returns the owner based on the most recently posted ownership document.

CREATE VIEW api.current_ownership AS
SELECT DISTINCT ON (deo.organization_id, deo.object_type, deo.object_id)
    deo.organization_id,
    deo.object_type,
    deo.object_id,
    deo.contractor_id AS owner_id,
    c.full_name       AS owner_name
FROM private.doc_ownership deo
JOIN private.documents d ON d.id = deo.document_id
JOIN private.contractors c ON c.id = deo.contractor_id
WHERE deo.status = 'posted'
  AND d.status   = 'posted'
ORDER BY deo.organization_id, deo.object_type, deo.object_id, d.posted_at DESC;

GRANT SELECT ON api.current_ownership TO authenticated;

COMMENT ON VIEW api.current_ownership IS
    'Текущий владелец объекта (plot, meter и т.д.) — по последнему проведённому документу владения. RLS через doc_ownership.organization_id.';
