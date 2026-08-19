-- demo subscription: what makes the credit module's two pools actually differ.
--
-- without a plan there is nothing to gate `is-pro` on, the subscription pool is
-- always spendable, and the split is invisible. these two tables are the
-- smallest thing that makes the difference real.

-- plans on offer. a real site would keep this in config; a table here so the
-- demo can render a chooser and price them.
create table if not exists plan (
  key       text primary key,
  name      text not null,
  frequency text not null check (frequency in ('month', 'year')),
  price     numeric(10,2) not null,
  currency  text not null default 'USD',
  credits   int not null check (credits > 0),   -- granted per period
  ordering  int not null default 0
);

-- one subscription per user.
--   active    - paying; subscription credits spendable
--   canceled  - will not renew, but the period already paid for still runs, so
--               the credits stay spendable until it ends
--   suspended - entitlement withdrawn for now ( unpaid invoice, staff action ).
--               the credits are deliberately left alone: is-pro turns them off
--               and turning it back on restores them exactly. zeroing here and
--               re-granting on resume is what loses or duplicates credits when
--               a suspension flaps or a cron re-runs.
--   expired   - over. credits are zeroed, and this is terminal.
-- active / canceled / suspended are freely interchangeable; only `advance`
-- produces `expired`.
create table if not exists subscription (
  key          serial primary key,
  owner        int not null references users(key) on delete cascade,
  plan         text not null references plan(key),
  state        text not null default 'active'
               check (state in ('active', 'canceled', 'suspended', 'expired')),
  period       text not null,              -- current billing period, 'YYYY-MM'
  createdtime  timestamp default now(),
  modifiedtime timestamp
);

-- at most one un-expired subscription per user; the demo has no upgrade flow.
-- suspended counts: being suspended is not an invitation to subscribe again.
create unique index if not exists subscription_owner_live
  on subscription (owner) where state <> 'expired';
create index if not exists subscription_owner on subscription (owner, key);

insert into plan (key, name, frequency, price, currency, credits, ordering) values
  ('basic',  'Basic',      'month',   5.00, 'USD',   300, 1),
  ('pro',    'Pro',        'month',  15.00, 'USD',  1000, 2),
  ('yearly', 'Pro Yearly', 'year',  150.00, 'USD', 12000, 3)
on conflict (key) do nothing;
