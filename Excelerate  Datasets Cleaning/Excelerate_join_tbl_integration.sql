-- =====================================================
-- Integrating Learner and Opportunity Dataset
-- =====================================================

-- DATABASE:
-- excelerate_Raw_datasets_db

-- SOURCE TABLES:
-- 1. learner_tbl
-- 2. opportunity_data

-- =====================================================
--  DEFINE INTEGRATION PLAN

-- Integration key:
-- learner_tbl.sk corresponds to opportunity_data.opportunity_id
-- after replacing the Learner# prefix with Opportunity#.

-- Example:
-- Learner#ABC123 -> Opportunity#ABC123

-- The raw source tables are not modified.
-- Data cleaning is not performed in this stage.

-- Verify the integration relationship:

SELECT
    COUNT(*) AS total_learner_rows,
    COUNT(o.opportunity_id) AS matched_learner_rows,
    COUNT(*) - COUNT(o.opportunity_id) AS unmatched_learner_rows
FROM learner_tbl l
LEFT JOIN opportunity_data o
    ON REPLACE(l.sk, 'Learner#', 'Opportunity#')
       = o.opportunity_id;



--  BUILDING INTEGRATED DATASET
-- =====================================================

DROP TABLE IF EXISTS integrated_learner_opportunity;

CREATE TABLE integrated_learner_opportunity AS
SELECT
    l.*,

    o.pk AS opportunity_pk,
    o.opportunity_id,
    o.badge,
    o.career_add_on,
    o.category AS opportunity_category,
    o.code AS opportunity_code,
    o.cohort AS opportunity_cohort,
    o.created_at AS opportunity_created_at,
    o.currency_type,
    o.current_editor,
    o.dropout_transaction,
    o.duration,
    o.duration_type,
    o.eligibility,
    o.fee AS opportunity_fee,
    o.image_link,
    o.is_archived,
    o.is_auto_approve,
    o.last_date_to_apply,
    o.location,
    o.long_description,
    o.microscholarship,
    o.modified_at AS opportunity_modified_at,
    o.name AS opportunity_name,
    o.not_started_transaction,
    o.panellist,
    o.reward,
    o.role,
    o.role_responsibility,
    o.short_description,
    o.summary,
    o.testimonial,
    o.tracking_questions

FROM learner_tbl l
LEFT JOIN opportunity_data o
    ON REPLACE(l.sk, 'Learner#', 'Opportunity#')
       = o.opportunity_id;


-- =====================================================
--  DOCUMENTING AND VERIFYING INTEGRATED STRUCTURE
-- =====================================================

-- Verify row counts:

SELECT
    COUNT(*) AS total_rows,
    COUNT(*) FILTER (WHERE opportunity_id IS NOT NULL)
        AS matched_rows,
    COUNT(*) FILTER (WHERE opportunity_id IS NULL)
        AS unmatched_rows
FROM integrated_learner_opportunity;


-- Verify columns and data types:

SELECT
    ordinal_position,
    column_name,
    data_type
FROM information_schema.columns
WHERE table_name = 'integrated_learner_opportunity'
ORDER BY ordinal_position;


-- Verify the total number of columns:

SELECT
    COUNT(*) AS total_columns
FROM information_schema.columns
WHERE table_name = 'integrated_learner_opportunity';


-- =====================================================
-- FINAL NOTES
-- =====================================================

-- Integrated table:
-- integrated_learner_opportunity

-- Total rows: 15,397
-- Matched rows: 14,799
-- Unmatched rows: 598
-- Total columns: 76

-- The 598 unmatched learner records are retained because
-- a LEFT JOIN was used.
-- Data cleaning and investigation in file name: Excelerate_dataset_cleaning.


