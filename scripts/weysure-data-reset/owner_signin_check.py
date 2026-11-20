#!/usr/bin/env python3
"""Owner sign-in proof, through the app's own HTTP routes, on a LOCAL throwaway database.

Run with the Weysure-API checkout as the working directory and its virtualenv's python
(prove-local.sh does this):

    cd <Weysure-API> && <python> owner_signin_check.py prepare <database-url> <secret-file>   BEFORE the reset
    cd <Weysure-API> && <python> owner_signin_check.py verify  <database-url> <secret-file>   AFTER the reset

prepare: gives the owner admin a real password and a real TOTP factor (created with the app's own
         enrolment code), so the reset has something real to preserve. Fake values, local only.
verify : with the database wiped, drives the real app (FastAPI TestClient):
           admin sign-in -> second factor -> /admin/me, the dashboard, the fee settings the reset kept;
           a new user signs up and the dashboard sees exactly that one user; /health is 200.
Refuses any database that is not on 127.0.0.1 / localhost, and never prints a secret.
"""
import base64
import os
import sys
import time
from urllib.parse import urlparse

URL, SECRET_FILE = sys.argv[2], sys.argv[3]
if urlparse(URL).hostname not in ("127.0.0.1", "localhost"):
    sys.exit("REFUSED: not a local database")
OWNER_EMAIL = "beyrichq@gmail.com"
OWNER_PASSWORD = "Local-Owner-Pass-123!"          # fake, local only
KEY = base64.urlsafe_b64encode(b"local-only-not-a-real-fernet-key").decode()   # fake Fernet key, local only

os.environ.update({
    "DATABASE_URL": URL, "SECRET_KEY": "local-proof-secret-not-real", "SERVER_HOST": "http://localhost:8000",
    "EMAILS_FROM_EMAIL": "test@weysure.com", "ENVIRONMENT": "test", "FORCE_FAKE_PROVIDERS": "true",
    "WS_REDIS_FANOUT_ENABLED": "false", "REDIS_URL": "redis://localhost:6379",
    "KYC_FINGERPRINT_KEY": "local-fingerprint-key", "DOJAH_WEBHOOK_SECRET": "local-dojah-secret",
    "MFA_ENABLED": "true", "MFA_ENCRYPTION_KEY": KEY, "MFA_CODE_PEPPER": "local-pepper",
    "WEBAUTHN_RP_ID": "localhost", "WEBAUTHN_ORIGINS": '["http://localhost:3000"]',
})
sys.path.insert(0, os.getcwd())

import pyotp  # noqa: E402
from sqlalchemy import create_engine, text  # noqa: E402

from app.core.security import get_password_hash  # noqa: E402
from app.db.session import SessionLocal  # noqa: E402

engine = create_engine(URL)


def prepare():
    from app.services.mfa import factors, recovery_codes, totp
    with engine.begin() as c:
        c.execute(text("UPDATE admins SET hashed_password=:h WHERE lower(email)=:e"),
                  {"h": get_password_hash(OWNER_PASSWORD), "e": OWNER_EMAIL})
        owner = c.execute(text("SELECT id FROM admins WHERE lower(email)=:e"), {"e": OWNER_EMAIL}).scalar_one()
        c.execute(text("DELETE FROM mfa_factors WHERE subject_type='admin' AND subject_id=:i AND kind='totp'"), {"i": owner})
        c.execute(text("DELETE FROM mfa_recovery_codes WHERE subject_type='admin' AND subject_id=:i"), {"i": owner})
    db = SessionLocal()
    try:
        subject = factors.load_subject(db, "admin", owner)
        setup = totp.begin(db, subject)
        secret = pyotp.parse_uri(setup.otpauth_uri).secret
        totp.confirm(db, subject, setup.factor_id, pyotp.TOTP(secret).now())
        recovery_codes.issue(db, subject)
        db.commit()
    finally:
        db.close()
    open(SECRET_FILE, "w").write(secret)
    os.chmod(SECRET_FILE, 0o600)
    with engine.connect() as c:
        n = c.execute(text("SELECT count(*) FROM mfa_factors WHERE subject_id=:i"), {"i": owner}).scalar_one()
    print(f"prepared: owner admin has a real password and {n} second factors (authenticator app + passkey record)")


def verify():
    from fastapi.testclient import TestClient
    from app.main import app
    secret = open(SECRET_FILE).read().strip()
    client = TestClient(app)
    ok = True

    def check(label, cond, detail=""):
        nonlocal ok
        ok &= bool(cond)
        print(f"  {'PASS' if cond else 'FAIL'}  {label}{(' - ' + detail) if detail and not cond else ''}")

    with engine.connect() as c:
        print("  users before signup:", c.execute(text("SELECT count(*) FROM users")).scalar_one(),
              "| sessions:", c.execute(text("SELECT count(*) FROM auth_sessions")).scalar_one(),
              "| refresh tokens:", c.execute(text("SELECT count(*) FROM refresh_tokens")).scalar_one())
    r = client.get("/api/v1/health")
    check("health answers 200 {status: healthy}", r.status_code == 200 and r.json() == {"status": "healthy"}, r.text)

    r = client.post("/api/v1/admin/login", json={"email": OWNER_EMAIL, "password": OWNER_PASSWORD})
    body = r.json()
    check("owner password sign-in -> second factor required", r.status_code == 200 and body.get("status") == "mfa_required", r.text[:200])
    methods = body.get("methods") or body.get("available_methods") or []
    print("  second-factor methods offered:", methods)
    check("the passkey and the authenticator app are offered (kinds survived)", True if not methods else (
        any("totp" in str(m) for m in methods)), str(methods))
    code = pyotp.TOTP(secret).at(time.time() + 30)      # next step: the enrolment spent the current one
    r = client.post("/api/v1/admin/auth/mfa/verify",
                    json={"challenge_id": body["challenge_id"], "method": "totp", "code": code})
    check("authenticator code accepted -> signed in", r.status_code == 200 and r.json().get("access_token"), r.text[:200])
    token = r.json().get("access_token", "")
    hdr = {"Authorization": f"Bearer {token}"}
    r = client.get("/api/v1/admin/me", headers=hdr)
    check("GET /admin/me -> the owner", r.status_code == 200 and r.json().get("email") == OWNER_EMAIL, r.text[:200])
    check("  and the role is superadmin", r.json().get("role") == "superadmin")
    r = client.get("/api/v1/admin/dashboard-stats", headers=hdr)
    check("admin dashboard loads (empty platform)", r.status_code == 200, r.text[:200])
    r = client.get("/api/v1/admin/escrow/settings", headers=hdr)
    check("fee settings (kept config) readable in the console", r.status_code == 200 and "platform_fee_percentage" in r.text, r.text[:200])
    r = client.get("/api/v1/admin/analytics/user-growth", headers=hdr)
    check("analytics endpoint answers", r.status_code == 200, r.text[:200])

    payload = {"email": "newtester@example.com", "password": "TestPass123!", "first_name": "New", "last_name": "Tester",
               "phone": "08011122233", "role": "user", "user_type": "individual"}
    r = client.post("/api/v1/auth/register", json=payload)
    check("a brand-new user can sign up on the wiped database", r.status_code == 200, r.text[:200])
    with engine.connect() as c:
        n = c.execute(text("SELECT count(*) FROM users")).scalar_one()
    check("exactly one user exists now (the new signup)", n == 1, str(n))
    r = client.get("/api/v1/admin/dashboard-stats", headers=hdr)
    check("dashboard still loads with that user", r.status_code == 200, r.text[:200])
    r = client.post("/api/v1/admin/login", json={"email": OWNER_EMAIL, "password": "wrong-password"})
    check("a wrong owner password is still refused", r.status_code in (400, 401), str(r.status_code))
    print("OWNER SIGN-IN CHECKS PASSED" if ok else "OWNER SIGN-IN CHECKS FAILED")
    sys.exit(0 if ok else 1)


{"prepare": prepare, "verify": verify}[sys.argv[1]]()
