-- demo site schema.

-- a priced "job" the demo lets users buy with credits. it exists to show the
-- credit.consume(work) pattern: the row is inserted inside the same transaction
-- as the deduction, so a failed insert refunds by rolling back rather than by
-- a compensating write.
create table if not exists demo_job (
  key         serial primary key,
  owner       int not null references users(key) on delete cascade,
  name        text not null,
  cost        int not null,
  createdtime timestamp default now()
);

create index if not exists demo_job_owner on demo_job (owner, key);

-- what a top-up bought. the credit module refers to rows here as
-- (ref_type='purchase', ref_id=<key>::text) with no foreign key of its own, so
-- this table is what makes "was this purchase reversed?" answerable:
--   amount   - credits granted
--   refunded - credits clawed back so far ( 0 / partial / == amount )
-- the money side is decorative here; a real site would carry gateway ids and a
-- payment state machine instead.
create table if not exists purchase (
  key          serial primary key,
  owner        int not null references users(key) on delete cascade,
  gateway      text,
  amount       int not null check (amount > 0),
  refunded     int not null default 0 check (refunded >= 0),
  price        numeric(10,2),
  currency     text not null default 'USD',
  createdtime  timestamp default now(),
  modifiedtime timestamp,
  constraint purchase_refunded_le_amount check (refunded <= amount)
);

create index if not exists purchase_owner on purchase (owner, key);
