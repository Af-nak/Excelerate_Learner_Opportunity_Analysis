-- ==========================================================
-- AUDITING DATA QUALITY
-- ==========================================================

-- 4.1 Categorize pk formats
SELECT
  CASE
    WHEN pk LIKE 'Learner#%' AND length(pk) > 8 THEN 'valid Learner#<id>'
    WHEN pk = 'Learner#' THEN 'bare "Learner#" (id missing)'
    WHEN pk = '' OR pk IS NULL THEN 'blank/NULL'
    ELSE 'garbage/corrupted'
  END AS pk_category,
  COUNT(*) AS rows,
  COUNT(DISTINCT pk) AS distinct_values
FROM integrated_learner_opportunity
GROUP BY 1
ORDER BY rows DESC;


-- 4.2 Repeated (pk, sk, opportunity_id) combinations
SELECT pk, sk, opportunity_id, COUNT(*)
FROM integrated_learner_opportunity
GROUP BY pk, sk, opportunity_id
HAVING COUNT(*) > 1
ORDER BY COUNT(*) DESC;


-- 4.2 JSON leaking into sk
SELECT COUNT(*) FILTER (WHERE sk LIKE '%fileType%') AS json_bleed_rows
FROM integrated_learner_opportunity;


-- 4.3 Unmatched rows: original (returned 0 because blank rows are NULL, not '')
SELECT COUNT(*) FROM integrated_learner_opportunity
WHERE opportunity_id IS NULL AND pk = '' AND sk = '';


-- 4.3 Unmatched rows: garbage pk rows (expected 230)
SELECT COUNT(*) FROM integrated_learner_opportunity
WHERE opportunity_id IS NULL AND pk <> '' AND pk NOT LIKE 'Learner#%';


-- 4.3 Unmatched rows: corrected query for fully blank rows (expected 368)
SELECT COUNT(*) FROM integrated_learner_opportunity
WHERE opportunity_id IS NULL AND (pk IS NULL OR pk = '') AND (sk IS NULL OR sk = '');


-- 4.4 Exact duplicate rows
SELECT COUNT(*) AS total_rows, COUNT(DISTINCT md5(t::text)) AS distinct_rows
FROM integrated_learner_opportunity t;


-- 4.5 Missing location, duration_type and status
SELECT
  COUNT(*) FILTER (WHERE location IS NULL OR trim(location) = '') AS blank_location,
  COUNT(*) FILTER (WHERE lower(trim(location)) = 'null') AS literal_null_location,
  COUNT(*) FILTER (WHERE duration_type IS NULL OR trim(duration_type) = '') AS blank_duration_type,
  COUNT(*) FILTER (WHERE status IS NULL OR trim(status) = '') AS blank_status
FROM integrated_learner_opportunity;


-- 4.6 fee/category conflicts
SELECT
  COUNT(*) FILTER (WHERE (fee = '' OR fee IS NULL)
                     AND opportunity_fee IS NOT NULL AND opportunity_fee <> '') AS fee_blank_opp_has_value,
  COUNT(*) FILTER (WHERE fee IS DISTINCT FROM opportunity_fee
                     AND fee <> '' AND opportunity_fee <> '') AS both_nonblank_different
FROM integrated_learner_opportunity WHERE opportunity_id IS NOT NULL;


-- 4.7 Location spelling variants
SELECT location, COUNT(*) AS opportunity_count
FROM integrated_learner_opportunity
GROUP BY location
ORDER BY opportunity_count DESC;


-- ==========================================================
-- APPLYING CLEANING RULES
-- ==========================================================

-- 5.1 Build the cleaned table
CREATE TABLE integrated_learner_opportunity_clean AS
WITH base AS (
  SELECT *,
    CASE WHEN lower(trim(location)) IN ('null','none','n/a','')
         THEN NULL ELSE location END AS location_clean,
    COALESCE(NULLIF(opportunity_fee,''), NULLIF(fee,'')) AS resolved_fee,
    COALESCE(NULLIF(opportunity_category,''), NULLIF(category,'')) AS resolved_category,
    ROW_NUMBER() OVER (PARTITION BY pk, sk, opportunity_id ORDER BY pk) AS rn
  FROM integrated_learner_opportunity
  WHERE NOT (pk = '' AND sk = '' AND opportunity_id IS NULL)          -- Rule 1a
    AND NOT (pk <> '' AND pk NOT LIKE 'Learner#%')                    -- Rule 1b
    AND NOT (sk LIKE '%fileType%')                                    -- Rule 1b
)
SELECT * FROM base WHERE rn = 1;


-- 5.2 Normalize location variants
UPDATE integrated_learner_opportunity_clean
SET location_clean = CASE
  WHEN lower(trim(location_clean)) IN ('virtual','vitrual') THEN 'Virtual'
  WHEN lower(trim(location_clean)) IN ('work from home','wfm','wfh') THEN 'Work From Home'
  WHEN location_clean IN ('Location','Opportunity name Page Testing','qwerty') THEN NULL
  WHEN location_clean IN ('Quia ad ipsum quos','Commodi et aut sunt','Quis voluptate totam',
                           'Recusandae Ex volup','Qui voluptatibus nat','Elit cum quis volup',
                           'Aliquam officia est','Animi iste aut anim') THEN NULL
  ELSE location_clean
END;


-- 5.3 Verify location result
SELECT location_clean, COUNT(*) FROM integrated_learner_opportunity_clean
GROUP BY location_clean ORDER BY COUNT(*) DESC NULLS LAST;


-- NOTE: Drop learner_tbl, opportunity_date, integrated_learner_opportunity

-- To select the table
SELECT * FROM integrated_learner_opportunity_clean;

-- Check the data type of all column
SELECT column_name, data_type FROM information_schema.columns
WHERE table_name = 'integrated_learner_opportunity_clean';

-- Check the appearance of the following column, Limit:20
SELECT
    fee,
    amount_to_be_paid,
    duration,
    opportunity_fee,
    microscholarship,
    resolved_fee,
    created_at,
    opportunity_created_at,
    is_archived,
    is_auto_approve,
    created_at,
    apply_date,
    completion_date,
    opportunity_created_at,
    opportunity_modified_at,
    last_date_to_apply
FROM integrated_learner_opportunity_clean
LIMIT 20;

-- Test conversion of date columns: created at, opportunity created at
SELECT
    created_at,
    TO_TIMESTAMP(created_at::NUMERIC / 1000) AS converted_created_at,

    opportunity_created_at,
    TO_TIMESTAMP(opportunity_created_at::NUMERIC / 1000)
        AS converted_opportunity_created_at

FROM integrated_learner_opportunity_clean
WHERE TRIM(created_at) <> ''
LIMIT 20;

-- Checking the max number that is causing numeric value over flow
SELECT
    MAX(ABS(NULLIF(NULLIF(TRIM(fee), ''), 'NULL')::NUMERIC)) AS max_fee,
    MAX(ABS(NULLIF(NULLIF(TRIM(amount_to_be_paid), ''), 'NULL')::NUMERIC)) AS max_amount_to_be_paid,
    MAX(ABS(NULLIF(NULLIF(TRIM(opportunity_fee), ''), 'NULL')::NUMERIC)) AS max_opportunity_fee,
    MAX(ABS(NULLIF(NULLIF(TRIM(microscholarship), ''), 'NULL')::NUMERIC)) AS max_microscholarship,
    MAX(ABS(NULLIF(NULLIF(TRIM(resolved_fee), ''), 'NULL')::NUMERIC)) AS max_resolved_fee
FROM integrated_learner_opportunity_clean;

-- Returns record with the max value causing neumeric type overflow
SELECT *
FROM integrated_learner_opportunity_clean
WHERE
    ABS(NULLIF(NULLIF(TRIM(fee), ''), 'NULL')::NUMERIC) = 6000000000000
    OR ABS(NULLIF(NULLIF(TRIM(amount_to_be_paid), ''), 'NULL')::NUMERIC) = 6000000000000
    OR ABS(NULLIF(NULLIF(TRIM(opportunity_fee), ''), 'NULL')::NUMERIC) = 6000000000000
    OR ABS(NULLIF(NULLIF(TRIM(microscholarship), ''), 'NULL')::NUMERIC) = 500000000
    OR ABS(NULLIF(NULLIF(TRIM(resolved_fee), ''), 'NULL')::NUMERIC) = 6000000000000;

-- Adjusted the numeric(12,2) clause to numeric to accomodate the large numbers
-- Changing the asuumed clean dataset datatype
CREATE TABLE learner_opportunity AS
SELECT
    rn,
    sk,
    assigned_cohort,

    -- Numeric fields
    NULLIF(NULLIF(TRIM(fee), ''), 'NULL')::NUMERIC AS fee,

    status,

    -- Dates
    CASE
    WHEN TRIM(accept_reject_date) = ''
         OR UPPER(TRIM(accept_reject_date)) = 'NULL'
        THEN NULL

    WHEN TRIM(accept_reject_date) ~ '^[0-9]+(\.[0-9]+)?([Ee][+-]?[0-9]+)?$'
        THEN TO_TIMESTAMP(TRIM(accept_reject_date)::NUMERIC / 1000)

    WHEN TRIM(accept_reject_date) ~ '^\d{4}-\d{2}-\d{2}T\d{2}\.\d{2}\.\d{2}'
        THEN REPLACE(
            TRIM(accept_reject_date),
            SUBSTRING(TRIM(accept_reject_date) FROM 12 FOR 8),
            REPLACE(SUBSTRING(TRIM(accept_reject_date) FROM 12 FOR 8), '.', ':')
        )::TIMESTAMPTZ

    WHEN TRIM(accept_reject_date) ~ '^\d{4}-\d{2}-\d{2}T'
        THEN TRIM(accept_reject_date)::TIMESTAMPTZ

    ELSE NULL
END AS accept_reject_date,
    NULLIF(NULLIF(TRIM(amount_to_be_paid), ''), 'NULL')::NUMERIC
        AS amount_to_be_paid,

    transaction_id,
    payment_status,

    i_agree_to_terms_and_conditions_of_global_shala,

    CASE
        WHEN TRIM(modified_at) = '' THEN NULL
        WHEN TRIM(modified_at) ~ '^[0-9]+(\.[0-9]+)?([Ee][+-]?[0-9]+)?$'
            THEN TO_TIMESTAMP(TRIM(modified_at)::NUMERIC / 1000)
        WHEN TRIM(modified_at) ~ '^\d{4}-\d{2}-\d{2}T'
            THEN TRIM(modified_at)::TIMESTAMPTZ
        ELSE NULL
    END AS modified_at,

    CASE
        WHEN TRIM(apply_date) = '' THEN NULL
        WHEN TRIM(apply_date) ~ '^[0-9]+(\.[0-9]+)?([Ee][+-]?[0-9]+)?$'
            THEN TO_TIMESTAMP(TRIM(apply_date)::NUMERIC / 1000)
        WHEN TRIM(apply_date) ~ '^\d{4}-\d{2}-\d{2}T'
            THEN TRIM(apply_date)::TIMESTAMPTZ
        ELSE NULL
    END AS apply_date,

    from_where_did_you_hear_about_us,
    accept_reject_reason,
    category,

    CASE
        WHEN TRIM(not_started_date) = '' THEN NULL
        WHEN TRIM(not_started_date) ~ '^[0-9]+(\.[0-9]+)?([Ee][+-]?[0-9]+)?$'
            THEN TO_TIMESTAMP(TRIM(not_started_date)::NUMERIC / 1000)
        WHEN TRIM(not_started_date) ~ '^\d{4}-\d{2}-\d{2}T'
            THEN TRIM(not_started_date)::TIMESTAMPTZ
        ELSE NULL
    END AS not_started_date,

    cohort_p2,
    cohort_p1,
    relation_id,

    CASE
        WHEN TRIM(reward_awarded_date) = '' THEN NULL
        WHEN TRIM(reward_awarded_date) ~ '^[0-9]+(\.[0-9]+)?([Ee][+-]?[0-9]+)?$'
            THEN TO_TIMESTAMP(TRIM(reward_awarded_date)::NUMERIC / 1000)
        WHEN TRIM(reward_awarded_date) ~ '^\d{4}-\d{2}-\d{2}T'
            THEN TRIM(reward_awarded_date)::TIMESTAMPTZ
        ELSE NULL
    END AS reward_awarded_date,

    CASE
        WHEN TRIM(completion_date) = '' THEN NULL
        WHEN TRIM(completion_date) ~ '^[0-9]+(\.[0-9]+)?([Ee][+-]?[0-9]+)?$'
            THEN TO_TIMESTAMP(TRIM(completion_date)::NUMERIC / 1000)
        WHEN TRIM(completion_date) ~ '^\d{4}-\d{2}-\d{2}T'
            THEN TRIM(completion_date)::TIMESTAMPTZ
        ELSE NULL
    END AS completion_date,

    withdraw_reason,
    team_name,
    team_code,
    application_id,
    i_have_read_and_agreed_to_the_terms_and_conditions,
    team_creator,
    send_for_approval_mechanism_t_c,
    please_identify_your_student_status,
    i_understand_that_i_will_have_to_commit_at_least56_hours_each_w,
    why_do_you_want_to_apply_for_this_internship1,
    i_will_be_available_from79_pm_ist730930_am_cst_for_meetings_onc,
    from_which_medium_did_you_hear_about_the_internship,
    why_do_you_want_to_apply_for_this_internship,

    CASE
        WHEN TRIM(withdraw_date) = '' THEN NULL
        WHEN TRIM(withdraw_date) ~ '^[0-9]+(\.[0-9]+)?([Ee][+-]?[0-9]+)?$'
            THEN TO_TIMESTAMP(TRIM(withdraw_date)::NUMERIC / 1000)
        WHEN TRIM(withdraw_date) ~ '^\d{4}-\d{2}-\d{2}T'
            THEN TRIM(withdraw_date)::TIMESTAMPTZ
        ELSE NULL
    END AS withdraw_date,

    CASE
        WHEN TRIM(created_at) = '' THEN NULL
        WHEN TRIM(created_at) ~ '^[0-9]+(\.[0-9]+)?([Ee][+-]?[0-9]+)?$'
            THEN TO_TIMESTAMP(TRIM(created_at)::NUMERIC / 1000)
        WHEN TRIM(created_at) ~ '^\d{4}-\d{2}-\d{2}T'
            THEN TRIM(created_at)::TIMESTAMPTZ
        ELSE NULL
    END AS created_at,

    external_reference_url,
    work_item_sk,
    i_understand_that_this_is_the_first_step_towards_my_application,
    how_did_you_hear_about_this_opportunity,
    can_you_share_an_experience_where_you_proactively_pursued_learn,

    CASE
        WHEN TRIM(dropped_out_date) = '' THEN NULL
        WHEN TRIM(dropped_out_date) ~ '^[0-9]+(\.[0-9]+)?([Ee][+-]?[0-9]+)?$'
            THEN TO_TIMESTAMP(TRIM(dropped_out_date)::NUMERIC / 1000)
        WHEN TRIM(dropped_out_date) ~ '^\d{4}-\d{2}-\d{2}T'
            THEN TRIM(dropped_out_date)::TIMESTAMPTZ
        ELSE NULL
    END AS dropped_out_date,

    appear_in_wishlist,

    -- Opportunity fields
    opportunity_pk,
    opportunity_id,
    badge,
    career_add_on,
    opportunity_category,
    opportunity_code,
    opportunity_cohort,

    CASE
        WHEN TRIM(opportunity_created_at) = '' THEN NULL
        WHEN TRIM(opportunity_created_at) ~ '^[0-9]+(\.[0-9]+)?([Ee][+-]?[0-9]+)?$'
            THEN TO_TIMESTAMP(TRIM(opportunity_created_at)::NUMERIC / 1000)
        WHEN TRIM(opportunity_created_at) ~ '^\d{4}-\d{2}-\d{2}T'
            THEN TRIM(opportunity_created_at)::TIMESTAMPTZ
        ELSE NULL
    END AS opportunity_created_at,

    currency_type,
    current_editor,
    dropout_transaction,

    CASE
        WHEN TRIM(duration) ~ '^[0-9]+$'
            THEN TRIM(duration)::INTEGER
        ELSE NULL
    END AS duration,

    duration_type,
    eligibility,

    NULLIF(NULLIF(TRIM(opportunity_fee), ''), 'NULL')::NUMERIC
        AS opportunity_fee,

    image_link,

    CASE
        WHEN UPPER(TRIM(is_archived)) = 'TRUE' THEN TRUE
        WHEN UPPER(TRIM(is_archived)) = 'FALSE' THEN FALSE
        ELSE NULL
    END AS is_archived,

    CASE
        WHEN UPPER(TRIM(is_auto_approve)) = 'TRUE' THEN TRUE
        WHEN UPPER(TRIM(is_auto_approve)) = 'FALSE' THEN FALSE
        ELSE NULL
    END AS is_auto_approve,

    CASE
        WHEN TRIM(last_date_to_apply) = '' THEN NULL
        WHEN TRIM(last_date_to_apply) ~ '^[0-9]+(\.[0-9]+)?([Ee][+-]?[0-9]+)?$'
            THEN TO_TIMESTAMP(TRIM(last_date_to_apply)::NUMERIC / 1000)
        WHEN TRIM(last_date_to_apply) ~ '^\d{4}-\d{2}-\d{2}T'
            THEN TRIM(last_date_to_apply)::TIMESTAMPTZ
        ELSE NULL
    END AS last_date_to_apply,

    location,
    long_description,
    NULLIF(NULLIF(TRIM(microscholarship), ''), 'NULL')::NUMERIC
        AS microscholarship,

    CASE
        WHEN TRIM(opportunity_modified_at) = '' THEN NULL
        WHEN TRIM(opportunity_modified_at) ~ '^[0-9]+(\.[0-9]+)?([Ee][+-]?[0-9]+)?$'
            THEN TO_TIMESTAMP(TRIM(opportunity_modified_at)::NUMERIC / 1000)
        WHEN TRIM(opportunity_modified_at) ~ '^\d{4}-\d{2}-\d{2}T'
            THEN TRIM(opportunity_modified_at)::TIMESTAMPTZ
        ELSE NULL
    END AS opportunity_modified_at,

    opportunity_name,
    not_started_transaction,
    panellist,
    pk,
    role,
    role_responsibility,
    short_description,
    summary,
    testimonial,
    tracking_questions,

    -- Already-cleaned/derived fields
    location_clean,

    NULLIF(NULLIF(TRIM(resolved_fee), ''), 'NULL')::NUMERIC
        AS resolved_fee,

    resolved_category,
    reward

FROM integrated_learner_opportunity_clean;

-- NOTE: Drop integrated_learner_opportunity_clean

-- conversion of text null to sql null
UPDATE learner_opportunity
SET
    appear_in_wishlist = NULLIF(NULLIF(TRIM(appear_in_wishlist), ''), 'NULL'),
    opportunity_pk = NULLIF(NULLIF(TRIM(opportunity_pk), ''), 'NULL'),
    opportunity_id = NULLIF(NULLIF(TRIM(opportunity_id), ''), 'NULL'),
    badge = NULLIF(NULLIF(TRIM(badge), ''), 'NULL'),
    career_add_on = NULLIF(NULLIF(TRIM(career_add_on), ''), 'NULL'),
    opportunity_category = NULLIF(NULLIF(TRIM(opportunity_category), ''), 'NULL'),
    opportunity_code = NULLIF(NULLIF(TRIM(opportunity_code), ''), 'NULL'),
    opportunity_cohort = NULLIF(NULLIF(TRIM(opportunity_cohort), ''), 'NULL'),
    currency_type = NULLIF(NULLIF(TRIM(currency_type), ''), 'NULL'),
    current_editor = NULLIF(NULLIF(TRIM(current_editor), ''), 'NULL'),
    dropout_transaction = NULLIF(NULLIF(TRIM(dropout_transaction), ''), 'NULL'),
    duration_type = NULLIF(NULLIF(TRIM(duration_type), ''), 'NULL'),
    eligibility = NULLIF(NULLIF(TRIM(eligibility), ''), 'NULL'),
    image_link = NULLIF(NULLIF(TRIM(image_link), ''), 'NULL'),
    location = NULLIF(NULLIF(TRIM(location), ''), 'NULL'),
    long_description = NULLIF(NULLIF(TRIM(long_description), ''), 'NULL'),
    not_started_transaction = NULLIF(NULLIF(TRIM(not_started_transaction), ''), 'NULL'),
    panellist = NULLIF(NULLIF(TRIM(panellist), ''), 'NULL'),
    pk = NULLIF(NULLIF(TRIM(pk), ''), 'NULL'),
    role = NULLIF(NULLIF(TRIM(role), ''), 'NULL'),
    role_responsibility = NULLIF(NULLIF(TRIM(role_responsibility), ''), 'NULL'),
    short_description = NULLIF(NULLIF(TRIM(short_description), ''), 'NULL'),
    summary = NULLIF(NULLIF(TRIM(summary), ''), 'NULL'),
    testimonial = NULLIF(NULLIF(TRIM(testimonial), ''), 'NULL'),
    tracking_questions = NULLIF(NULLIF(TRIM(tracking_questions), ''), 'NULL'),
    location_clean = NULLIF(NULLIF(TRIM(location_clean), ''), 'NULL'),
    resolved_category = NULLIF(NULLIF(TRIM(resolved_category), ''), 'NULL'),
    reward = NULLIF(NULLIF(TRIM(reward), ''), 'NULL');

	COMMIT
	
-- clean and standardised dataset

UPDATE learner_opportunity
SET location = INITCAP(LOWER(location));

UPDATE learner_opportunity
SET location = CASE
	WHEN TRIM(location) IN ('Vitrual', 'Virtual') THEN 'Virtual'
	WHEN TRIM(location) IN ('Wfm', 'Work From Home') THEN 'Work From Home'
	WHEN LOWER(TRIM(location)) IN (
        'quia ad ipsum quos',
        'commodi et aut sunt',
        'opportunity name page testing',
        'quis voluptate totam',
        'qui voluptatibus nat',
        'recusandae ex volup',
        'qwerty',
        'elit cum quis volup',
        'aliquam officia est',
        'animi iste aut anim'
    )
        THEN NULL

    ELSE TRIM(location)
END;

--duration_type: 14 mispellings to 6 real spellings
SELECT duration_type, COUNT(*) FROM learner_opportunity
GROUP BY duration_type ORDER BY COUNT(*) DESC;         

UPDATE learner_opportunity
SET duration_type = CASE
  WHEN lower(trim(duration_type)) IN ('week','weeks')            THEN 'Week'
  WHEN lower(trim(duration_type)) IN ('month','months')          THEN 'Month'
  WHEN lower(trim(duration_type)) IN ('hour','hours')            THEN 'Hour'
  WHEN lower(trim(duration_type)) IN ('day','days','da')         THEN 'Day'    
  WHEN lower(trim(duration_type)) IN ('minute','minutes')        THEN 'Minute'
  WHEN lower(trim(duration_type)) IN ('year','years','yearssss') THEN 'Year'     
  WHEN trim(duration_type) = '' OR duration_type IS NULL         THEN NULL
  ELSE duration_type
END;

SELECT duration_type, COUNT(*) FROM learner_opportunity
GROUP BY duration_type ORDER BY COUNT(*) DESC;          

--EUR and EURO are the same currency
SELECT currency_type, COUNT(*) FROM learner_opportunity
GROUP BY currency_type ORDER BY COUNT(*) DESC;          

UPDATE learner_opportunity
SET currency_type = 'EUR'
WHERE upper(trim(currency_type)) = 'EURO';

SELECT currency_type, COUNT(*) FROM learner_opportunity
GROUP BY currency_type ORDER BY COUNT(*) DESC;          


--Location header fix, two null rows 

SELECT location, COUNT(*) FROM learner_opportunity
GROUP BY location ORDER BY COUNT(*) DESC;               

UPDATE learner_opportunity
SET location = NULL
WHERE trim(location) = 'Location';

SELECT location, COUNT(*) FROM learner_opportunity
GROUP BY location ORDER BY COUNT(*) DESC;               

UPDATE learner_opportunity
SET location = NULL
WHERE lower(trim(location)) = 'null';

--there were two null rows combined them 
SELECT location, COUNT(*) FROM learner_opportunity GROUP BY location ORDER BY COUNT(*) DESC;


--the location column above is now correct, so drop this
ALTER TABLE learner_opportunity DROP COLUMN IF EXISTS location_clean;


-- convert the three yes/no text columns to real boolean type
-- (matches how is_archived / is_auto_approve were already converted)
ALTER TABLE learner_opportunity
  ALTER COLUMN i_agree_to_terms_and_conditions_of_global_shala TYPE boolean
  USING (CASE WHEN upper(trim(i_agree_to_terms_and_conditions_of_global_shala)) = 'TRUE' THEN TRUE
              WHEN upper(trim(i_agree_to_terms_and_conditions_of_global_shala)) = 'FALSE' THEN FALSE
              ELSE NULL END);

ALTER TABLE learner_opportunity
  ALTER COLUMN i_have_read_and_agreed_to_the_terms_and_conditions TYPE boolean
  USING (CASE WHEN upper(trim(i_have_read_and_agreed_to_the_terms_and_conditions)) = 'TRUE' THEN TRUE
              WHEN upper(trim(i_have_read_and_agreed_to_the_terms_and_conditions)) = 'FALSE' THEN FALSE
              ELSE NULL END);

ALTER TABLE learner_opportunity
  ALTER COLUMN i_will_be_available_from79_pm_ist730930_am_cst_for_meetings_onc TYPE boolean
  USING (CASE WHEN lower(trim(i_will_be_available_from79_pm_ist730930_am_cst_for_meetings_onc)) = 'yes' THEN TRUE
              WHEN lower(trim(i_will_be_available_from79_pm_ist730930_am_cst_for_meetings_onc)) = 'no' THEN FALSE
              ELSE NULL END);

-- REMOVING ANOMALIES AND EXTREME OUTLIERS IN DATASETS
-- ---------------------------------------------------------------------
-- 0. Rules used (each one is a condition on a record)
--
--  R1  Placeholder / invalid learner key (removing bare learner id with it records in t he  datasets)
--  R2  Role contains "test"                       (447 records after R1)
--  R3  Duration longer than 4 years               (139 records after R1)
--  R4  Fee outlier of 6 trillion                  (  7 records after R1)
--
-- Duration is converted to years from duration + duration_type:
--   Minute / (60*24*365.25)   Hour / (24*365.25)   Day / 365.25
--   Week * 7 / 365.25         Month / 12           Year as is
-- ---------------------------------------------------------------------


-- ---------------------------------------------------------------------
-- 1. PREVIEW: how many records each rule catches
--    (R2-R4 are counted only on records that survive R1)
-- ---------------------------------------------------------------------
WITH valid AS (
    SELECT *
    FROM learner_opportunity
    WHERE pk IS NOT NULL
      AND TRIM(pk) <> ''
      AND pk <> 'Learner#'
      AND pk LIKE 'Learner#%'
      AND LENGTH(pk) > 8
),
flagged AS (
    SELECT
        pk,
        opportunity_id,
        CASE WHEN LOWER(COALESCE(role, '')) LIKE '%test%' THEN 1 ELSE 0 END AS r2_test_role,
        CASE WHEN CAST(duration AS DECIMAL(20,4)) /
                  CASE duration_type
                      WHEN 'Minute' THEN 60 * 24 * 365.25
                      WHEN 'Hour'   THEN 24 * 365.25
                      WHEN 'Day'    THEN 365.25
                      WHEN 'Week'   THEN 365.25 / 7
                      WHEN 'Month'  THEN 12
                      WHEN 'Year'   THEN 1
                  END > 4 THEN 1 ELSE 0 END                                AS r3_duration_over_4y,
        CASE WHEN CAST(opportunity_fee AS DECIMAL(30,2)) >= 1000000000000
             THEN 1 ELSE 0 END                                              AS r4_fee_outlier
    FROM valid
)
SELECT
    COUNT(*)                                                        AS records_after_r1,
    SUM(r2_test_role)                                               AS r2_test_role,
    SUM(r3_duration_over_4y)                                        AS r3_duration_over_4y,
    SUM(r4_fee_outlier)                                             AS r4_fee_outlier,
    SUM(CASE WHEN r2_test_role + r3_duration_over_4y + r4_fee_outlier > 0
             THEN 1 ELSE 0 END)                                     AS removed_by_r2_r3_r4
FROM flagged;
-- Expected: 9063 | 447 | 139 | 7 | 581


-- ---------------------------------------------------------------------
-- 2. DELETE: remove every record caught by any rule (R1 to R4)
--    The conditions are combined with OR, so a record caught by two
--    rules (12 records) is deleted once.
-- ---------------------------------------------------------------------
DELETE FROM learner_opportunity
WHERE
    -- R1: placeholder or invalid learner key (your query, same logic)
    pk IS NULL
    OR TRIM(pk) = ''
    OR pk = 'Learner#'
    OR NOT (pk LIKE 'Learner#%' AND LENGTH(pk) > 8)

    -- R2: role contains "test" (any case)
    OR LOWER(COALESCE(role, '')) LIKE '%test%'

    -- R3: duration longer than 4 years
    OR CAST(duration AS DECIMAL(20,4)) /
       CASE duration_type
           WHEN 'Minute' THEN 60 * 24 * 365.25
           WHEN 'Hour'   THEN 24 * 365.25
           WHEN 'Day'    THEN 365.25
           WHEN 'Week'   THEN 365.25 / 7
           WHEN 'Month'  THEN 12
           WHEN 'Year'   THEN 1
       END > 4

    -- R4: fee outlier (6,000,000,000,000)
    OR CAST(opportunity_fee AS DECIMAL(30,2)) >= 1000000000000;



-- 3. VERIFY the result
-- ---------------------------------------------------------------------
SELECT
    COUNT(*)                       AS records,
    COUNT(DISTINCT opportunity_id) AS distinct_opportunities,
    COUNT(DISTINCT pk)             AS distinct_learners
FROM learner_opportunity;

-- Expected: 8482 | 3045 | 551
-----------

-- check null in important field

SELECT
    COUNT(*) FILTER (WHERE pk IS NULL) AS null_learner_pk,
    COUNT(*) FILTER (WHERE sk IS NULL) AS null_sk,
    COUNT(*) FILTER (WHERE opportunity_id IS NULL) AS null_opportunity_id,
    COUNT(*) FILTER (WHERE status IS NULL) AS null_status,
    COUNT(*) FILTER (WHERE fee IS NULL) AS null_fee,
    COUNT(*) FILTER (WHERE amount_to_be_paid IS NULL) AS null_amount_to_be_paid
FROM learner_opportunity;

-- check for distinct learners and count of  total records
SELECT
    COUNT(*) AS total_rows,
    COUNT(DISTINCT pk) AS distinct_learners
FROM learner_opportunity;

-- how many opportunities each learner have
SELECT
   pk,
    COUNT(DISTINCT opportunity_id) AS opportunities
FROM learner_opportunity
GROUP BY pk
ORDER BY opportunities DESC;

-- checking if fee values are sensible

SELECT
    MIN(fee) AS minimum_fee,
    MAX(fee) AS maximum_fee,
    AVG(fee) AS average_fee
FROM learner_opportunity;

-- checking data quality on duration
SELECT
    MIN(duration) AS minimum_duration,
    MAX(duration) AS maximum_duration,
    AVG(duration) AS average_duration
FROM learner_opportunity;

-- checking if it will answer a question
-- How many opportunity applied for by category
SELECT
    category,
    COUNT(*) AS opportunity_count
FROM learner_opportunity
GROUP BY category
ORDER BY opportunity_count DESC;

-- opportunities by Location
SELECT
    location,
    COUNT(*) AS opportunity_count
FROM learner_opportunity
GROUP BY location
ORDER BY opportunity_count DESC;

-- Average fee by category
SELECT
    category,
    COUNT(*) AS opportunity_count,
    ROUND(AVG(fee), 2) AS average_fee
FROM learner_opportunity
GROUP BY category
ORDER BY average_fee DESC;


SELECT
    status,
    COUNT(*) AS application_count
FROM learner_opportunity
GROUP BY status
ORDER BY application_count DESC;

-- cohort analysis
SELECT
    assigned_cohort,
    COUNT(*) AS learner_count
FROM learner_opportunity
GROUP BY assigned_cohort
ORDER BY learner_count DESC;


