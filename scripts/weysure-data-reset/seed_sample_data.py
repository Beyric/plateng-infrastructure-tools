#!/usr/bin/env python3
"""Fill a LOCAL, throwaway Weysure database with sample rows in every table, to prove db-reset-prod-v1.

    python3 -I seed_sample_data.py "postgresql://user:pass@127.0.0.1:55432/weysure"

Refuses any host other than 127.0.0.1 / localhost. All values are obviously fake (example.test
emails, "x" hashes, placeholder credential ids): nothing here is real personal data.

Two layers:
  1. hand-made rows: the owner's admin (+ a TOTP and a passkey-style factor + recovery codes), two
     other admins with factors, a user with a factor, config rows that another admin edited
     (so the reset has to un-point them), an escrow_settings row;
  2. a generic generator that inserts rows into EVERY remaining table in foreign-key order,
     reading column types, NOT NULL, foreign keys and enums from the catalog. Tables whose CHECK
     rules reject a generic row are reported (and listed in SKIPPED_OK if expected).
"""
import base64
import hashlib
import json
import sys
import uuid
from collections import defaultdict
from urllib.parse import urlparse

import psycopg2
import psycopg2.extras

OWNER_EMAIL = "beyrichq@gmail.com"
# A passkey credential id is base64url bytes; this one decodes to the text "placeholder-credential-id".
PLACEHOLDER_CREDENTIAL_ID = base64.urlsafe_b64encode(b"placeholder-credential-id").decode().rstrip("=")
ROWS = defaultdict(lambda: 3, {
    "wallet_transactions": 40, "security_audit_logs": 25, "notifications": 15, "usage_logs": 30,
    "messages": 20, "escrow_transaction_history": 12, "webhook_deliveries": 10,
})
# Values for columns whose CHECK rules reject a generic value.
OVERRIDES = {
    "account_freezes": {"reason_type": "chargeback"},
    "business_profiles": {"status": "approved"},
    "kyc_records": {"purpose": "tier2"},
    "manual_payout_requests": {"basis": "untraceable"},
    "deal_invites": {"status": "pending", "email_normalized": "invitee@example.test", "resend_count": 0},
    "dva_credits": {"origin": "own_bank", "gross_kobo": 100000, "fee_kobo": 0, "credited": 1000},
    "chargeback_events": {"source": "webhook"},
    "risk_signal_sightings": {"kind": "ip"},
    "kyc_reviews": {"sof_category": "salary", "status": "pending"},
    "source_refunds": {"amount": 1000, "amount_kobo": 100000},
}
CONFIG_TABLES = {"alembic_version", "settings", "delivery_method_settings", "kyc_tier_limits",
                 "risk_hold_settings", "escrow_settings"}
HAND_MADE = {"admins", "mfa_factors", "mfa_recovery_codes"}


def main(url):
    host = urlparse(url).hostname
    if host not in ("127.0.0.1", "localhost", "::1"):
        sys.exit(f"REFUSED: {host} is not a local database")
    conn = psycopg2.connect(url)
    conn.autocommit = False
    cur = conn.cursor()
    cur.execute("select current_database(), current_user")
    print("seeding", cur.fetchone())

    owner = "adm-owner-0001"
    other = "adm-qa-0002"
    other2 = "adm-qa-0003"
    uid = "usr-sample-0001"

    # ---- hand-made layer ---------------------------------------------------------------
    for aid, email, role in ((owner, OWNER_EMAIL, "superadmin"), (other, "qa-admin@example.test", "admin"),
                             (other2, "second-super@example.test", "superadmin")):
        cur.execute("""insert into admins (id, email, hashed_password, is_active, first_name, last_name, role,
                       password_pending, created_at, updated_at) values (%s,%s,'x-not-a-real-hash',true,'Sample','Admin',%s,false,now(),now())""",
                    (aid, email, role))
    for fid, sub_t, sub_id, kind, label in (
            ("fac-owner-totp", "admin", owner, "totp", "Authenticator app"),
            ("fac-owner-passkey", "admin", owner, "webauthn", "Owner passkey (placeholder)"),
            ("fac-qa-totp", "admin", other, "totp", "QA authenticator"),
            ("fac-qa2-totp", "admin", other2, "totp", "Second admin authenticator"),
            ("fac-user-totp", "user", uid, "totp", "Tester authenticator")):
        cur.execute("""insert into mfa_factors (id, subject_type, subject_id, kind, label, totp_secret_enc, webauthn_credential_id,
                       webauthn_public_key, webauthn_sign_count, confirmed_at, created_at)
                       values (%s,%s,%s,%s,%s,%s,%s,%s,%s,now(),now())""",
                    (fid, sub_t, sub_id, kind, label,
                     "placeholder-encrypted" if kind == "totp" else None,
                     PLACEHOLDER_CREDENTIAL_ID if kind == "webauthn" else None,
                     b"\x01\x02" if kind == "webauthn" else None, 7 if kind == "webauthn" else None))
    for sub_t, sub_id in (("admin", owner), ("admin", other), ("admin", other2), ("user", uid)):
        for i in range(8):
            cur.execute("""insert into mfa_recovery_codes (id, subject_type, subject_id, code_hash, batch_id, created_at)
                           values (%s,%s,%s,%s,%s,now())""",
                        (f"rc-{sub_id}-{i}", sub_t, sub_id, hashlib.sha256(f"{sub_id}{i}".encode()).hexdigest(), f"batch-{sub_id}"))

    # config edited by *another* admin, plus a fee row (no seed in migrations: created by an admin)
    cur.execute("update kyc_tier_limits set updated_by_admin_id=%s where tier=2", (other,))
    cur.execute("update risk_hold_settings set updated_by_id=%s", (other2,))
    cur.execute("update delivery_method_settings set updated_by_id=%s where method='local_delivery'", (other,))
    cur.execute("update settings set value='250000' where key='kyc_transaction_threshold'")
    cur.execute("insert into escrow_settings (id, platform_fee_percentage, updated_by_id) values (%s, 1.5, %s)",
                (str(uuid.uuid4()), other))
    conn.commit()

    # ---- generic layer -----------------------------------------------------------------
    tables = [r[0] for r in _q(cur, "select tablename from pg_tables where schemaname='public'")]
    skip = CONFIG_TABLES | HAND_MADE
    pending = [t for t in tables if t not in skip]
    fks = defaultdict(dict)        # table -> col -> (parent_table, parent_col)
    for t, c, pt, pc in _q(cur, """
        select cl.relname, a.attname, pcl.relname, pa.attname
          from pg_constraint k join pg_class cl on cl.oid=k.conrelid join pg_class pcl on pcl.oid=k.confrelid
          join pg_attribute a on a.attrelid=k.conrelid and a.attnum=k.conkey[1]
          join pg_attribute pa on pa.attrelid=k.confrelid and pa.attnum=k.confkey[1]
         where k.contype='f' and cl.relnamespace='public'::regnamespace and array_length(k.conkey,1)=1"""):
        fks[t][c] = (pt, pc)

    seeded = {"admins": [owner, other, other2]}
    seeded["users"] = []
    failures = {}
    for pass_no in range(8):
        progressed = False
        for t in list(pending):
            ok, err = _seed_table(conn, cur, t, fks[t], seeded, uid if t == "users" else None, owner, other)
            if ok:
                pending.remove(t)
                progressed = True
                failures.pop(t, None)
            else:
                failures[t] = err
        if not pending or not progressed:
            break
    conn.commit()

    # polymorphic session rows for the owner admin (no FK: subject_type/subject_id)
    cur.execute("""insert into auth_sessions (id, subject_type, subject_id, created_at, last_seen_at)
                   values ('sess-owner-1','admin',%s,now(),now())""", (owner,))
    cur.execute("""insert into refresh_tokens (id, family_id, subject_type, subject_id, token_hash, binding, created_at,
                   family_started_at, expires_at) values ('rt-owner-1','sess-owner-1','admin',%s,%s,'b',now(),now(),now()+interval '30 days')""",
                (owner, hashlib.sha256(b"rt-owner-1").hexdigest()))
    conn.commit()

    total = 0
    for (t,) in _q(cur, "select tablename from pg_tables where schemaname='public' order by 1"):
        cur.execute(f'select count(*) from public."{t}"')
        total += cur.fetchone()[0]
    print(f"seeded; total rows now {total}; tables that could not be seeded: {sorted(pending) or 'none'}")
    for t in pending:
        print("  ", t, failures.get(t))
    conn.close()
    return 0 if not pending else 1


def _q(cur, sql, args=None):
    cur.execute(sql, args)
    return cur.fetchall()


def _columns(cur, table):
    return _q(cur, """select column_name, data_type, udt_name, is_nullable, character_maximum_length,
                      numeric_precision, numeric_scale, column_default, is_generated, is_identity
                      from information_schema.columns where table_schema='public' and table_name=%s order by ordinal_position""", (table,))


def _value(cur, table, col, dtype, udt, maxlen, prec, scale, i):
    if dtype in ("character varying", "text", "character"):
        if col == "email" or col.endswith("_email"):
            v = f"{table}-{i}@example.test"
        else:
            v = f"{col}-{i}"
        return v[:maxlen] if maxlen else v
    if dtype in ("integer", "smallint", "bigint"):
        return i + 1
    if dtype == "numeric":
        cap = 10 ** ((prec or 10) - (scale or 0) - 1) if prec else 10 ** 6
        return min(1000 + i, cap - 1)
    if dtype in ("double precision", "real"):
        return 1.5
    if dtype == "boolean":
        return False
    if dtype.startswith("timestamp"):
        return "now()"
    if dtype == "date":
        return "now()::date"
    if dtype in ("json", "jsonb"):
        return psycopg2.extras.Json({})
    if dtype == "bytea":
        return psycopg2.Binary(b"\x01")
    if dtype == "uuid":
        return str(uuid.uuid4())
    if dtype == "USER-DEFINED":
        labels = [r[0] for r in _q(cur, "select e.enumlabel from pg_enum e join pg_type t on t.oid=e.enumtypid where t.typname=%s order by e.enumsortorder", (udt,))]
        return labels[i % len(labels)] if labels else None
    if dtype == "ARRAY":
        return []
    return f"{col}-{i}"


def _seed_table(conn, cur, table, fks, seeded, fixed_first_id, owner, other):
    cols = _columns(cur, table)
    n = ROWS[table]
    ids = []
    cur.execute("savepoint s")
    try:
        for i in range(n):
            names, vals, exprs = [], [], []
            for (col, dtype, udt, nullable, maxlen, prec, scale, default, gen, ident) in cols:
                if gen == "ALWAYS" or ident == "YES":
                    continue
                if col in fks:
                    pt, pc = fks[col]
                    if pt == "admins":
                        v = [owner, other][i % 2]
                    elif pt in seeded and seeded[pt]:
                        v = seeded[pt][i % len(seeded[pt])]
                    elif nullable == "YES":
                        continue
                    else:
                        raise RuntimeError(f"parent {pt} not seeded yet")
                elif col in OVERRIDES.get(table, {}):
                    v = OVERRIDES[table][col]
                elif col == "id" and default is not None:
                    continue  # serial / identity: the database numbers it
                elif col == "id":
                    v = fixed_first_id if (fixed_first_id and i == 0) else f"{table[:20]}-{i:04d}"
                elif default is not None and nullable == "NO" and dtype not in ("character varying", "text"):
                    continue  # a server default fills it
                elif nullable == "YES" and col not in ("email",):
                    continue
                else:
                    if col == "subject_type":
                        v = "user"
                    else:
                        v = _value(cur, table, col, dtype, udt, maxlen, prec, scale, i)
                names.append(f'"{col}"')
                if isinstance(v, str) and v in ("now()", "now()::date"):
                    exprs.append(v)
                else:
                    exprs.append("%s")
                    vals.append(v)
            sql = f'insert into public."{table}" ({", ".join(names)}) values ({", ".join(exprs)}) returning *'
            cur.execute(sql, vals)
            row = cur.fetchone()
            desc = [d[0] for d in cur.description]
            rowd = dict(zip(desc, row))
            ids.append(rowd.get("id") if "id" in rowd else None)
        cur.execute("release savepoint s")
        seeded[table] = [x for x in ids if x is not None]
        return True, None
    except Exception as exc:  # noqa: BLE001 - reported, then retried on the next pass
        cur.execute("rollback to savepoint s")
        return False, str(exc).strip().splitlines()[0]


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
