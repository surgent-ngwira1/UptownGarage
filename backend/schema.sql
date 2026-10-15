-- ============================================================
-- UPTOWN GARAGE - Integrated Garage & Auto Parts Management
-- PostgreSQL schema (designed for Neon)
-- ============================================================
--
-- This is a FULL re-initialization script: it drops and recreates
-- every object, then seeds the base staff accounts. Run it against a
-- fresh/empty database (e.g. the Neon dev branch).
--
-- The design is aligned with every feature implemented in
-- backend/controllers and consumed by frontend/src:
--   * users / auth & roles (customer, admin, manager, mechanic)
--   * vehicles, appointments (booking -> check-in -> job card)
--   * services catalog (Home + Manage Services)
--   * parts inventory + stock movements (stock-in, adjust, low-stock)
--   * job cards (diagnosis, work, approvals, schedule, verify, close)
--   * online parts orders (cart -> review -> confirm -> collect)
--   * invoices + payments (generate from job/order, partial payments)
--   * notifications and audit trail
-- ============================================================

-- ---------------- Clean slate (order: dependents first) ----------------
DROP VIEW  IF EXISTS v_low_stock_parts;
DROP VIEW  IF EXISTS v_invoice_summary;

DROP TABLE IF EXISTS audit_logs      CASCADE;
DROP TABLE IF EXISTS notifications   CASCADE;
DROP TABLE IF EXISTS payments        CASCADE;
DROP TABLE IF EXISTS invoices        CASCADE;
DROP TABLE IF EXISTS job_parts       CASCADE;
DROP TABLE IF EXISTS stock_movements CASCADE;
DROP TABLE IF EXISTS order_items     CASCADE;
DROP TABLE IF EXISTS orders          CASCADE;
DROP TABLE IF EXISTS job_approvals   CASCADE;
DROP TABLE IF EXISTS job_cards       CASCADE;
DROP TABLE IF EXISTS appointments    CASCADE;
DROP TABLE IF EXISTS parts           CASCADE;
DROP TABLE IF EXISTS services        CASCADE;
DROP TABLE IF EXISTS vehicles        CASCADE;
DROP TABLE IF EXISTS users           CASCADE;

DROP FUNCTION IF EXISTS set_updated_at() CASCADE;

DROP TYPE IF EXISTS payment_status   CASCADE;
DROP TYPE IF EXISTS invoice_source   CASCADE;
DROP TYPE IF EXISTS order_status     CASCADE;
DROP TYPE IF EXISTS movement_type    CASCADE;
DROP TYPE IF EXISTS approval_status  CASCADE;
DROP TYPE IF EXISTS job_status       CASCADE;
DROP TYPE IF EXISTS appointment_status CASCADE;
DROP TYPE IF EXISTS user_role        CASCADE;

-- ---------------- Enumerated domains ----------------
CREATE TYPE user_role          AS ENUM ('customer', 'admin', 'manager', 'mechanic');
CREATE TYPE appointment_status AS ENUM ('Pending','Confirmed','Arrived','Converted','Cancelled','No-show');
CREATE TYPE job_status AS ENUM (
  'Booked','Vehicle Checked In','Inspection','Awaiting Approval','Approved',
  'In Progress','Waiting for Parts','Completed','Ready for Collection','Collected'
);
CREATE TYPE approval_status    AS ENUM ('Pending','Approved','Rejected');
CREATE TYPE movement_type      AS ENUM ('in','used','sold','adjustment');
CREATE TYPE order_status       AS ENUM ('Pending','Confirmed','Rejected','Ready for Collection','Completed','Cancelled');
CREATE TYPE invoice_source     AS ENUM ('job','order','combined');
CREATE TYPE payment_status     AS ENUM ('Unpaid','Partially Paid','Paid','Refunded','Cancelled');

-- ============================================================
-- 1. USERS  - one login table shared by every role
-- ============================================================
CREATE TABLE users (
  id            SERIAL PRIMARY KEY,
  name          VARCHAR(150) NOT NULL,
  email         VARCHAR(150) UNIQUE NOT NULL,
  phone         VARCHAR(30),
  password_hash VARCHAR(255) NOT NULL,           -- bcrypt
  role          user_role    NOT NULL DEFAULT 'customer',
  specialty     VARCHAR(100),                    -- mechanics e.g. 'Engine', 'Electrical'
  is_active     BOOLEAN      NOT NULL DEFAULT TRUE,
  created_by    INT REFERENCES users(id) ON DELETE SET NULL,
  created_at    TIMESTAMP    NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMP    NOT NULL DEFAULT NOW()
);

-- ============================================================
-- 2. VEHICLES  - owned by a customer
-- ============================================================
CREATE TABLE vehicles (
  id           SERIAL PRIMARY KEY,
  customer_id  INT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  make         VARCHAR(80) NOT NULL,
  model        VARCHAR(80) NOT NULL,
  year         INT CHECK (year IS NULL OR year BETWEEN 1900 AND 2100),
  plate_number VARCHAR(30) UNIQUE NOT NULL,
  vin          VARCHAR(50),
  created_at   TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMP NOT NULL DEFAULT NOW()
);

-- ============================================================
-- 3. SERVICES  - public catalog shown on the Home page
--    and managed from the admin "Manage Services" screen.
-- ============================================================
CREATE TABLE services (
  id              SERIAL PRIMARY KEY,
  name            VARCHAR(150) NOT NULL,
  description     TEXT,
  estimated_price NUMERIC(12,2) CHECK (estimated_price IS NULL OR estimated_price >= 0),
  image_url       VARCHAR(500),
  is_active       BOOLEAN   NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMP NOT NULL DEFAULT NOW()
);

-- ============================================================
-- 4. PARTS  - inventory / parts catalog
-- ============================================================
CREATE TABLE parts (
  id              SERIAL PRIMARY KEY,
  name            VARCHAR(150) NOT NULL,
  sku             VARCHAR(50)  UNIQUE NOT NULL,
  description     TEXT,
  category        VARCHAR(80),                    -- free-text facet (tyre, battery, ...)
  image_url       VARCHAR(500),
  unit_price      NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (unit_price >= 0),
  quantity        INT NOT NULL DEFAULT 0 CHECK (quantity >= 0),
  min_stock_level INT NOT NULL DEFAULT 5 CHECK (min_stock_level >= 0),
  created_at      TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMP NOT NULL DEFAULT NOW()
);

-- ============================================================
-- 5. APPOINTMENTS  - customer booking -> confirmation -> check-in
-- ============================================================
CREATE TABLE appointments (
  id             SERIAL PRIMARY KEY,
  customer_id    INT NOT NULL REFERENCES users(id)    ON DELETE RESTRICT,
  vehicle_id     INT NOT NULL REFERENCES vehicles(id) ON DELETE RESTRICT,
  service_type   VARCHAR(150) NOT NULL,
  requested_date TIMESTAMP NOT NULL,
  status         appointment_status NOT NULL DEFAULT 'Pending',
  notes          TEXT,
  confirmed_by   INT REFERENCES users(id) ON DELETE SET NULL,
  created_at     TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMP NOT NULL DEFAULT NOW()
);

-- ============================================================
-- 6. JOB CARDS  - the workshop job / service order
-- ============================================================
CREATE TABLE job_cards (
  id                   SERIAL PRIMARY KEY,
  job_number           VARCHAR(30) UNIQUE NOT NULL,
  customer_id          INT NOT NULL REFERENCES users(id)    ON DELETE RESTRICT,
  vehicle_id           INT NOT NULL REFERENCES vehicles(id) ON DELETE RESTRICT,
  appointment_id       INT REFERENCES appointments(id) ON DELETE SET NULL,
  assigned_mechanic_id INT REFERENCES users(id) ON DELETE SET NULL,
  reported_problem     TEXT NOT NULL,
  diagnosis            TEXT,
  work_performed       TEXT,
  completion_notes     TEXT,
  status               job_status NOT NULL DEFAULT 'Booked',
  opened_at            TIMESTAMP NOT NULL DEFAULT NOW(),
  verified_by          INT REFERENCES users(id) ON DELETE SET NULL,
  closed_at            TIMESTAMP,
  scheduled_start      TIMESTAMP,
  scheduled_end        TIMESTAMP,
  updated_at           TIMESTAMP NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_job_window CHECK (
    scheduled_start IS NULL OR scheduled_end IS NULL OR scheduled_end > scheduled_start
  )
);

-- ============================================================
-- 7. JOB APPROVALS  - extra work found during inspection
-- ============================================================
CREATE TABLE job_approvals (
  id             SERIAL PRIMARY KEY,
  job_id         INT NOT NULL REFERENCES job_cards(id) ON DELETE CASCADE,
  description    TEXT NOT NULL,
  estimated_cost NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (estimated_cost >= 0),
  status         approval_status NOT NULL DEFAULT 'Pending',
  requested_by   INT REFERENCES users(id) ON DELETE SET NULL,
  decided_by     INT REFERENCES users(id) ON DELETE SET NULL,
  requested_at   TIMESTAMP NOT NULL DEFAULT NOW(),
  decided_at     TIMESTAMP
);

-- ============================================================
-- 8. ORDERS  - online parts orders placed by customers
-- ============================================================
CREATE TABLE orders (
  id          SERIAL PRIMARY KEY,
  customer_id INT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  status      order_status NOT NULL DEFAULT 'Pending',
  reviewed_by INT REFERENCES users(id) ON DELETE SET NULL,
  created_at  TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMP NOT NULL DEFAULT NOW()
);

-- ============================================================
-- 9. ORDER ITEMS  - M:N resolver (orders <-> parts)
-- ============================================================
CREATE TABLE order_items (
  id         SERIAL PRIMARY KEY,
  order_id   INT NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  part_id    INT NOT NULL REFERENCES parts(id)  ON DELETE RESTRICT,
  quantity   INT NOT NULL CHECK (quantity > 0),
  unit_price NUMERIC(12,2) NOT NULL CHECK (unit_price >= 0)   -- snapshot at order time
);

-- ============================================================
-- 10. STOCK MOVEMENTS  - every stock change is logged
-- ============================================================
CREATE TABLE stock_movements (
  id                 SERIAL PRIMARY KEY,
  part_id            INT NOT NULL REFERENCES parts(id) ON DELETE RESTRICT,
  type               movement_type NOT NULL,
  quantity           INT NOT NULL,                 -- negative on manual downward adjustment
  reference_job_id   INT REFERENCES job_cards(id) ON DELETE SET NULL,
  reference_order_id INT REFERENCES orders(id)   ON DELETE SET NULL,
  reason             TEXT,
  created_by         INT REFERENCES users(id) ON DELETE SET NULL,
  created_at         TIMESTAMP NOT NULL DEFAULT NOW()
);

-- ============================================================
-- 11. JOB PARTS  - M:N resolver (job_cards <-> parts)
-- ============================================================
CREATE TABLE job_parts (
  id         SERIAL PRIMARY KEY,
  job_id     INT NOT NULL REFERENCES job_cards(id) ON DELETE CASCADE,
  part_id    INT NOT NULL REFERENCES parts(id)     ON DELETE RESTRICT,
  quantity   INT NOT NULL CHECK (quantity > 0),
  unit_price NUMERIC(12,2) NOT NULL CHECK (unit_price >= 0)
);

-- ============================================================
-- 12. INVOICES  - generated from a job, an order, or both
-- ============================================================
CREATE TABLE invoices (
  id             SERIAL PRIMARY KEY,
  invoice_number VARCHAR(30) UNIQUE NOT NULL,
  source_type    invoice_source NOT NULL,
  job_id         INT REFERENCES job_cards(id) ON DELETE SET NULL,
  order_id       INT REFERENCES orders(id)    ON DELETE SET NULL,
  customer_id    INT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  labour_charge  NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (labour_charge >= 0),
  subtotal       NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
  discount       NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (discount  >= 0),
  total          NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (total     >= 0),
  status         payment_status NOT NULL DEFAULT 'Unpaid',
  created_at     TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMP NOT NULL DEFAULT NOW()
);

-- One invoice per source document (partial unique: NULLs allowed)
CREATE UNIQUE INDEX uq_invoices_job   ON invoices (job_id)   WHERE job_id   IS NOT NULL;
CREATE UNIQUE INDEX uq_invoices_order ON invoices (order_id) WHERE order_id IS NOT NULL;

-- ============================================================
-- 13. PAYMENTS  - against an invoice (supports part-payment)
-- ============================================================
CREATE TABLE payments (
  id          SERIAL PRIMARY KEY,
  invoice_id  INT NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
  amount      NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  method      VARCHAR(50) NOT NULL DEFAULT 'Cash',
  paid_at     TIMESTAMP NOT NULL DEFAULT NOW(),
  recorded_by INT REFERENCES users(id) ON DELETE SET NULL
);

-- ============================================================
-- 14. NOTIFICATIONS  - in-app messages per user
-- ============================================================
CREATE TABLE notifications (
  id         SERIAL PRIMARY KEY,
  user_id    INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  message    TEXT NOT NULL,
  is_read    BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- ============================================================
-- 15. AUDIT LOGS  - immutable activity trail
-- ============================================================
CREATE TABLE audit_logs (
  id             SERIAL PRIMARY KEY,
  user_id        INT REFERENCES users(id) ON DELETE SET NULL,
  role           user_role,
  action         VARCHAR(150) NOT NULL,
  affected_table VARCHAR(100),
  affected_id    INT,
  previous_value TEXT,
  new_value      TEXT,
  reason         TEXT,
  created_at     TIMESTAMP NOT NULL DEFAULT NOW()
);

-- ============================================================
-- INDEXES  - search / filter / join performance
-- ============================================================
CREATE INDEX idx_users_name            ON users (LOWER(name));
CREATE INDEX idx_users_email           ON users (LOWER(email));
CREATE INDEX idx_users_role            ON users (role);

CREATE INDEX idx_vehicles_customer     ON vehicles (customer_id);

CREATE INDEX idx_services_active       ON services (is_active);

CREATE INDEX idx_parts_name            ON parts (LOWER(name));
CREATE INDEX idx_parts_sku             ON parts (LOWER(sku));
CREATE INDEX idx_parts_category        ON parts (LOWER(category));
CREATE INDEX idx_parts_price           ON parts (unit_price);

CREATE INDEX idx_appointments_customer ON appointments (customer_id);
CREATE INDEX idx_appointments_status   ON appointments (status);
CREATE INDEX idx_appointments_date     ON appointments (requested_date);

CREATE INDEX idx_job_cards_customer    ON job_cards (customer_id);
CREATE INDEX idx_job_cards_status      ON job_cards (status);
CREATE INDEX idx_job_cards_mechanic_window
  ON job_cards (assigned_mechanic_id, scheduled_start, scheduled_end);

CREATE INDEX idx_job_approvals_job     ON job_approvals (job_id);

CREATE INDEX idx_orders_customer       ON orders (customer_id);
CREATE INDEX idx_orders_status         ON orders (status);
CREATE INDEX idx_order_items_order     ON order_items (order_id);
CREATE INDEX idx_order_items_part      ON order_items (part_id);

CREATE INDEX idx_stock_movements_part  ON stock_movements (part_id);
CREATE INDEX idx_stock_movements_job   ON stock_movements (reference_job_id);
CREATE INDEX idx_stock_movements_order ON stock_movements (reference_order_id);

CREATE INDEX idx_job_parts_job         ON job_parts (job_id);
CREATE INDEX idx_job_parts_part        ON job_parts (part_id);

CREATE INDEX idx_invoices_customer     ON invoices (customer_id);
CREATE INDEX idx_invoices_status       ON invoices (status);
CREATE INDEX idx_payments_invoice      ON payments (invoice_id);

CREATE INDEX idx_notifications_user    ON notifications (user_id, is_read);
CREATE INDEX idx_audit_logs_created    ON audit_logs (created_at);

-- ============================================================
-- updated_at maintenance trigger
-- ============================================================
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_users_updated        BEFORE UPDATE ON users        FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_vehicles_updated     BEFORE UPDATE ON vehicles     FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_services_updated     BEFORE UPDATE ON services     FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_parts_updated        BEFORE UPDATE ON parts        FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_appointments_updated BEFORE UPDATE ON appointments FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_job_cards_updated    BEFORE UPDATE ON job_cards    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_orders_updated       BEFORE UPDATE ON orders       FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_invoices_updated     BEFORE UPDATE ON invoices     FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================
-- REPORTING VIEWS  (read-only helpers for dashboards/reports)
-- ============================================================
CREATE VIEW v_invoice_summary AS
SELECT
  i.*,
  u.name AS customer_name,
  COALESCE(p.amount_paid, 0)                    AS amount_paid,
  i.total - COALESCE(p.amount_paid, 0)          AS balance
FROM invoices i
JOIN users u ON u.id = i.customer_id
LEFT JOIN (
  SELECT invoice_id, SUM(amount) AS amount_paid
  FROM payments
  GROUP BY invoice_id
) p ON p.invoice_id = i.id;

CREATE VIEW v_low_stock_parts AS
SELECT * FROM parts WHERE quantity <= min_stock_level;

-- ============================================================
-- SEED DATA
-- ============================================================
-- Base accounts. Both log in with the password:  Passw0rd!
-- (bcrypt hash below - change it after first login, or run
-- backend/tools/hash_password.php to generate a new one)
INSERT INTO users (name, email, password_hash, role) VALUES
('System Manager',      'calebphiri98@gmail.com',  '$2y$10$nFUwXD1bTvuv4oMRXiMNsevZkLSOBi7NBatfPEnCDum9mmYNoGLCG', 'manager'),
('Garage Administrator','calebphiri918@gmail.com', '$2y$10$nFUwXD1bTvuv4oMRXiMNsevZkLSOBi7NBatfPEnCDum9mmYNoGLCG', 'admin');

-- Starter service catalog so the public Home page is populated.
INSERT INTO services (name, description, estimated_price) VALUES
('General Service',    'Oil and filter change, fluid top-up and multi-point safety inspection.',          45000),
('Brake Service',      'Inspection and replacement of brake pads, discs and brake fluid.',                85000),
('Battery Replacement','Diagnostics, removal of the old battery and fitment of a new battery.',           70000),
('Wheel Alignment',    'Laser wheel alignment to restore correct steering and even tyre wear.',           35000),
('Engine Diagnostics', 'Computerised fault-code scan and expert engine troubleshooting.',                  50000),
('Tyre Fitting',       'Fitting, balancing and rotation of tyres.',                                     30000);
