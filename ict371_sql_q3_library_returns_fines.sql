-- ============================================================================
-- ICT371 Advanced Database
-- Question 3: Library Returns and Overdue Fines (50 marks)
-- PostgreSQL Implementation
-- ============================================================================

BEGIN;

DROP VIEW IF EXISTS v_overdue_loans CASCADE;
DROP TABLE IF EXISTS overdue_summary CASCADE;
DROP TABLE IF EXISTS loan_audit CASCADE;
DROP TABLE IF EXISTS loans CASCADE;
DROP TABLE IF EXISTS books CASCADE;

-- ----------------------------------------------------------------------------
-- (a) Database and seed data [6 marks]
-- ----------------------------------------------------------------------------
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title   VARCHAR(200) NOT NULL
);

CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INTEGER NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(120) NOT NULL,
    borrowed_on   DATE NOT NULL,
    due_on        DATE NOT NULL CHECK (due_on >= borrowed_on),
    returned_on   DATE NULL CHECK (returned_on IS NULL OR returned_on >= borrowed_on),
    fine_amount   NUMERIC(10, 2) NOT NULL DEFAULT 0.00 CHECK (fine_amount >= 0)
);

CREATE TABLE loan_audit (
    audit_id        SERIAL PRIMARY KEY,
    loan_id         INTEGER NOT NULL REFERENCES loans(loan_id),
    old_returned_on DATE NULL,
    new_returned_on DATE NULL,
    changed_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INTEGER NOT NULL CHECK (overdue_count >= 0),
    total_fine    NUMERIC(12, 2) NOT NULL CHECK (total_fine >= 0)
);

-- ----------------------------------------------------------------------------
-- (b) Function: fn_loan_fine(p_loan_id, p_as_of) [6 marks]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_loan_fine(
    p_loan_id INTEGER,
    p_as_of   DATE DEFAULT CURRENT_DATE
) RETURNS NUMERIC(10, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_due_on      DATE;
    v_returned_on DATE;
    v_eff_date    DATE;
    v_days_late   INTEGER;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'Evaluation date (p_as_of) cannot be NULL.';
    END IF;

    SELECT due_on, returned_on
      INTO v_due_on, v_returned_on
      FROM loans
     WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    IF v_returned_on IS NOT NULL THEN
        v_eff_date := LEAST(p_as_of, v_returned_on);
    ELSE
        v_eff_date := p_as_of;
    END IF;

    v_days_late := GREATEST(0, v_eff_date - v_due_on);
    RETURN ROUND(v_days_late * 2.00, 2);
END;
$$;

-- ----------------------------------------------------------------------------
-- (c) Procedure: pr_return_loan(p_loan_id, p_returned_on) [8 marks]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_return_loan(
    p_loan_id     INTEGER,
    p_returned_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrowed_on DATE;
    v_returned_on DATE;
    v_final_fine  NUMERIC(10, 2);
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date (p_returned_on) cannot be NULL.';
    END IF;

    SELECT borrowed_on, returned_on
      INTO v_borrowed_on, v_returned_on
      FROM loans
     WHERE loan_id = p_loan_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    IF v_returned_on IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % has already been returned on %.', p_loan_id, v_returned_on;
    END IF;

    IF p_returned_on < v_borrowed_on THEN
        RAISE EXCEPTION 'Return date (%) cannot precede borrowed date (%).',
            p_returned_on, v_borrowed_on;
    END IF;

    v_final_fine := fn_loan_fine(p_loan_id, p_returned_on);

    UPDATE loans
       SET returned_on = p_returned_on,
           fine_amount = v_final_fine
     WHERE loan_id = p_loan_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- (d) Trigger: AFTER UPDATE row trigger on loans [8 marks]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_loans_return_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.returned_on IS DISTINCT FROM OLD.returned_on THEN
        INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
        VALUES (NEW.loan_id, OLD.returned_on, NEW.returned_on, NOW());
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_loans_return_audit
AFTER UPDATE ON loans
FOR EACH ROW
EXECUTE FUNCTION trg_fn_loans_return_audit();

-- ----------------------------------------------------------------------------
-- (a cont.) Seed 3 books and 6 loans (open overdue, on-time, returned)
-- ----------------------------------------------------------------------------
INSERT INTO books (title) VALUES
    ('Database System Concepts'),
    ('Introduction to the Theory of Computation'),
    ('Operating System Concepts');

INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on, returned_on, fine_amount) VALUES
    (1, 'Kelvin Zulu',     CURRENT_DATE - 20, CURRENT_DATE - 6,  NULL, 0.00), -- open overdue (6 days -> K12)
    (2, 'Mercy Tembo',     CURRENT_DATE - 15, CURRENT_DATE - 2,  NULL, 0.00), -- open overdue (2 days -> K4)
    (3, 'Bwalya Mulenga',  CURRENT_DATE - 5,  CURRENT_DATE + 5,  NULL, 0.00), -- open on-time
    (1, 'Natasha Chanda',  CURRENT_DATE - 3,  CURRENT_DATE,      NULL, 0.00), -- due today (not overdue)
    (2, 'Brian Sakala',    CURRENT_DATE - 14, CURRENT_DATE - 7,  NULL, 0.00), -- will be returned late below
    (3, 'Lombe Kasonde',   CURRENT_DATE - 10, CURRENT_DATE - 3,  NULL, 0.00); -- will be returned on time below

CALL pr_return_loan(5, CURRENT_DATE - 4); -- 3 days late -> K6 fine
CALL pr_return_loan(6, CURRENT_DATE - 3); -- on due date -> K0 fine

-- ----------------------------------------------------------------------------
-- (e) View: v_overdue_loans [5 marks]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT
    l.loan_id,
    b.title AS book_title,
    l.borrower_name,
    l.due_on,
    fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE
ORDER BY l.due_on ASC;

SELECT * FROM v_overdue_loans;

-- ----------------------------------------------------------------------------
-- (f) Index & EXPLAIN [5 marks]
-- Justification: A partial B-tree index on (book_id) WHERE returned_on IS NULL
-- indexes only active unreturned loans, keeping the index small and enabling
-- fast lookup of open loans for any specific book.
-- ----------------------------------------------------------------------------
CREATE INDEX idx_loans_book_unreturned
    ON loans (book_id)
    WHERE returned_on IS NULL;

EXPLAIN
SELECT loan_id, book_id, borrower_name, borrowed_on, due_on
  FROM loans
 WHERE book_id = 1
   AND returned_on IS NULL;

-- ----------------------------------------------------------------------------
-- (g) Scheduled job: pr_refresh_overdue(p_as_of) & pg_cron [6 marks]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_overdue_count INTEGER;
    v_total_fine    NUMERIC(12, 2);
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'Snapshot date (p_as_of) cannot be NULL.';
    END IF;

    SELECT COUNT(*),
           COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0.00)
      INTO v_overdue_count, v_total_fine
      FROM loans
     WHERE (returned_on IS NULL OR returned_on > p_as_of)
       AND due_on < p_as_of;

    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    VALUES (p_as_of, v_overdue_count, v_total_fine)
    ON CONFLICT (snapshot_date) DO UPDATE
        SET overdue_count = EXCLUDED.overdue_count,
            total_fine    = EXCLUDED.total_fine;
END;
$$;

CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);

COMMIT;

-- Schedule daily at 00:10 for CURRENT_DATE
SELECT cron.schedule(
    'library_daily_overdue_refresh',
    '10 0 * * *',
    $$CALL pr_refresh_overdue(CURRENT_DATE);$$
);
