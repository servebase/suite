
-- @servebase/credit schema.
--
-- depends on servebase's `users` table only. references to host-application
-- tables ( purchase, bill_agreement, ... ) are kept as loose (ref_type, ref_id)
-- pairs on purpose: this module must install on a plain servebase database.

-- current balance per user, split by pool (fast reads; not the ledger)
create table if not exists credit (
  owner        int not null references users(key) on delete cascade,
  pool         text not null check (pool in ('purchase', 'subscription')),
  balance      int not null default 0 check (balance >= 0),
  modifiedtime timestamp default now(),
  primary key (owner, pool)
);

-- immutable ledger of every credit movement
create table if not exists credit_log (
  key           serial primary key,
  owner         int not null references users(key) on delete cascade,
  delta         int not null check (delta != 0),
  action        text not null check (action in
                  ('grant', 'expire', 'consume', 'purchase', 'refund', 'adjust')),
  source_type   text,               -- subscription | purchase | staff | <feature-key>
  pool          text not null check (pool in ('subscription', 'purchase')),
  ref_type      text,               -- referenced table (bill_agreement, purchase, ...)
  ref_id        text,               -- key in that table (text: future-proof for non-integer keys)
  by_user       int references users(key) on delete set null,  -- operator, for staff adjust
  memo          text,               -- required for staff adjust (enforced by module)
  period        text,               -- billing period start, for cron grant idempotency
  pool_balance  int not null check (pool_balance >= 0),   -- balance of `pool` after this row
  total_balance int not null check (total_balance >= 0),  -- subscription + purchase after this tx
  createdtime   timestamp default now()
);

create index if not exists credit_log_owner on credit_log (owner, createdtime);
create index if not exists credit_log_ref   on credit_log (ref_type, ref_id);
-- one subscription grant per agreement per billing period (cron re-run guard)
create unique index if not exists credit_log_grant_period
  on credit_log (owner, ref_type, ref_id, period)
  where action = 'grant' and period is not null;

-- per-grant remaining for the purchase pool: FIFO consumption, per-grant refund.
-- invariant: sum(remaining) per owner == balance of that owner's purchase pool.
-- every purchase-pool addition creates a row; every deduction decrements FIFO.
create table if not exists credit_grant (
  key          serial primary key,
  owner        int not null references users(key) on delete cascade,
  ref_type     text,   -- host table this grant came from (purchase, ...); null for staff adjust
  ref_id       text,   -- key in that table. no fk: host schema is unknown to this module
  amount       int not null check (amount > 0),
  remaining    int not null check (remaining >= 0),
  expiretime   timestamp,   -- null = never expires
  createdtime  timestamp default now()
);

create index if not exists credit_grant_ref on credit_grant (ref_type, ref_id);
-- the expiry sweep's only query. partial, because the rows it must never look
-- at ( exhausted, or never expiring ) are the overwhelming majority.
create index if not exists credit_grant_due on credit_grant (expiretime)
  where remaining > 0 and expiretime is not null;

create index if not exists credit_grant_open on credit_grant (owner, key) where remaining > 0;
