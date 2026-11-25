-- =====================================================================
-- ICT371 Advanced Database | Student No: 202407871
-- QUESTION 10: Scholarship Application Assessment  (50 marks)
-- Run with:  psql -d yourdb -f ICT371_202407871_Q10_Scholarship.sql
-- Objects live in schema q10_scholarship; the script can be re-run safely.
-- Rule: age 18-25 inclusive AND monthly income <= K3,000 AND mark >= 70.
-- =====================================================================
DROP SCHEMA IF EXISTS q10_scholarship CASCADE;
CREATE SCHEMA q10_scholarship;
SET search_path TO q10_scholarship, public;

-- ---------------------------------------------------------------------
-- (a) DATABASE AND SEED DATA [6]
-- ---------------------------------------------------------------------
CREATE TABLE students (
    student_id      SERIAL       PRIMARY KEY,
    student_number  VARCHAR(20)  NOT NULL UNIQUE,
    full_name       VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id      SERIAL        PRIMARY KEY,
    student_id          INTEGER       NOT NULL REFERENCES students(student_id),
    age_at_application  INTEGER       NOT NULL CHECK (age_at_application > 0),
    monthly_income      NUMERIC(10,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark        NUMERIC(5,2)  NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on        DATE          NOT NULL DEFAULT CURRENT_DATE,
    status              VARCHAR(10)   NOT NULL DEFAULT 'PENDING',
    CONSTRAINT chk_status CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id        SERIAL      PRIMARY KEY,
    application_id  INTEGER     NOT NULL REFERENCES applications(application_id),
    old_status      VARCHAR(10) NOT NULL,
    new_status      VARCHAR(10) NOT NULL,
    changed_at      TIMESTAMP   NOT NULL DEFAULT now()
);

INSERT INTO students (student_number, full_name) VALUES
    ('2024201', 'Natasha Kabwe'),
    ('2024202', 'Kelvin Mumba'),
    ('2024203', 'Sarah Lungu');

-- Six PENDING applications: qualifying, non-qualifying and boundary cases
INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
    (1, 20, 2500.00, 75.00, CURRENT_DATE - 10, 'PENDING'),   -- 1 qualifies
    (1, 26, 1000.00, 90.00, CURRENT_DATE - 9,  'PENDING'),   -- 2 age 26 -> reject
    (2, 18, 3000.00, 70.00, CURRENT_DATE - 8,  'PENDING'),   -- 3 ALL lower boundaries -> qualifies
    (2, 25, 3000.00, 70.00, CURRENT_DATE - 7,  'PENDING'),   -- 4 upper age boundary   -> qualifies
    (3, 22, 3000.01, 80.00, CURRENT_DATE - 6,  'PENDING'),   -- 5 income just above    -> reject
    (3, 22, 2000.00, 69.99, CURRENT_DATE - 5,  'PENDING');   -- 6 mark just below      -> reject

-- ---------------------------------------------------------------------
-- (b) FUNCTION fn_scholarship_eligible [6]
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INTEGER, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark must not be NULL';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive, got %', p_age;
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income must not be negative, got %', p_income;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100, got %', p_mark;
    END IF;

    RETURN p_age BETWEEN 18 AND 25
       AND p_income <= 3000
       AND p_mark >= 70;
END;
$$;

-- ---------------------------------------------------------------------
-- (c) PROCEDURE pr_assess_application [8]
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
    v_age     INTEGER;
    v_income  NUMERIC;
    v_mark    NUMERIC;
    v_status  VARCHAR(10);
    v_ok      BOOLEAN;
BEGIN
    SELECT age_at_application, monthly_income, average_mark, status
    INTO   v_age, v_income, v_mark, v_status
    FROM   applications
    WHERE  application_id = p_application_id
    FOR UPDATE;                                   -- lock: two runs cannot assess the same row

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application_id: %', p_application_id;
    END IF;
    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % has already been assessed (status %)', p_application_id, v_status;
    END IF;

    v_ok := fn_scholarship_eligible(v_age, v_income, v_mark);

    UPDATE applications
    SET    status = CASE WHEN v_ok THEN 'APPROVED' ELSE 'REJECTED' END
    WHERE  application_id = p_application_id;
END;
$$;

-- ---------------------------------------------------------------------
-- (d) TRIGGER AFTER UPDATE [8]
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_decision_audit()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
    VALUES (OLD.application_id, OLD.status, NEW.status, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_applications_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_fn_decision_audit();

-- ---------------------------------------------------------------------
-- (e) VIEW v_approved_applicants [5]  (no income column)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number,
       s.full_name,
       a.average_mark,
       a.status
FROM   applications a
JOIN   students s ON s.student_id = a.student_id
WHERE  a.status = 'APPROVED';

-- ---------------------------------------------------------------------
-- (f) INDEX [5]
-- Equality on status first, range on submitted_on second.
-- ---------------------------------------------------------------------
CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);
ANALYZE applications;

-- ---------------------------------------------------------------------
-- (g) SCHEDULED JOB [6]
-- Only PENDING rows are selected, and each is assessed once (status
-- leaves PENDING), so reruns find nothing to do: no re-assessment and
-- no duplicate audit rows.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT application_id
        FROM   applications
        WHERE  status = 'PENDING'
        ORDER  BY application_id
    LOOP
        CALL pr_assess_application(r.application_id);
    END LOOP;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Every Monday at 08:00
SELECT cron.schedule('q10_assess_pending', '0 8 * * 1',
                     $$CALL q10_scholarship.pr_assess_pending()$$);

SELECT jobid, jobname, schedule, command, active FROM cron.job WHERE jobname = 'q10_assess_pending';
-- SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;

-- =====================================================================
-- TESTS / EVIDENCE
-- =====================================================================
\echo '--- (a) Six PENDING applications ---'
SELECT * FROM applications ORDER BY application_id;

\echo '--- (b) Function: boundaries and invalid input ---'
SELECT fn_scholarship_eligible(18, 3000, 70)    AS lower_boundary_true,
       fn_scholarship_eligible(25, 3000, 70)    AS upper_age_true,
       fn_scholarship_eligible(17, 1000, 90)    AS age_17_false,
       fn_scholarship_eligible(26, 1000, 90)    AS age_26_false,
       fn_scholarship_eligible(20, 3000.01, 90) AS income_over_false,
       fn_scholarship_eligible(20, 1000, 69.99) AS mark_under_false;
DO $$ BEGIN PERFORM fn_scholarship_eligible(NULL, 1, 1);
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (NULL): %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, -1, 50);
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (negative income): %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(0, 1, 50);
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (age 0): %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, 1, 101);
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (mark 101): %', SQLERRM; END $$;

\echo '--- (c) Procedure: one application, then errors ---'
CALL pr_assess_application(1);
SELECT application_id, status FROM applications WHERE application_id = 1;     -- APPROVED
DO $$ BEGIN CALL pr_assess_application(1);
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (already assessed): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_assess_application(999);
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (unknown): %', SQLERRM; END $$;

\echo '--- (d) Trigger: one audit row so far; unchanged status adds none ---'
SELECT * FROM decision_audit ORDER BY audit_id;
UPDATE applications SET status = status WHERE application_id = 1;              -- unchanged
UPDATE applications SET average_mark = 76.00 WHERE application_id = 1;         -- other column
SELECT COUNT(*) AS audit_rows_still_1 FROM decision_audit;

\echo '--- (g) Scheduled procedure processes the remaining 5 PENDING; rerun does nothing ---'
CALL pr_assess_pending();
SELECT application_id, age_at_application, monthly_income, average_mark, status
FROM applications ORDER BY application_id;                    -- 1,3,4 APPROVED ; 2,5,6 REJECTED
SELECT COUNT(*) AS audit_rows_after_first_run FROM decision_audit;   -- 6
CALL pr_assess_pending();                                     -- rerun
SELECT COUNT(*) AS audit_rows_after_rerun FROM decision_audit;       -- still 6

\echo '--- (e) View: approved only, no income ---'
SELECT * FROM v_approved_applicants ORDER BY student_number;

\echo '--- (f) EXPLAIN ---'
SET enable_seqscan = off;
EXPLAIN SELECT * FROM applications
WHERE status = 'APPROVED' AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;
