diff --git a/app.py b/app.py
index d44149dd5c20e91a6ba93d616a0201a1ae4147f0..5a2ad19245c8ddd074737635444d233f5603f1f0 100644
--- a/app.py
+++ b/app.py
@@ -1,69 +1,603 @@
-from flask import Flask, request, jsonify
-import smtplib
-from email.mime.multipart import MIMEMultipart
-from email.mime.application import MIMEApplication
 import os
+import secrets
+import sqlite3
+from datetime import datetime, timedelta
+from functools import wraps
 
-app = Flask(__name__)
-
-SMTP_ACCOUNTS = [
-    {
-        "host": os.getenv("SMTP1_HOST"),
-        "port": int(os.getenv("SMTP1_PORT")),
-        "login": os.getenv("SMTP1_LOGIN"),
-        "password": os.getenv("SMTP1_PASSWORD")
-    },
-    {
-        "host": os.getenv("SMTP2_HOST"),
-        "port": int(os.getenv("SMTP2_PORT")),
-        "login": os.getenv("SMTP2_LOGIN"),
-        "password": os.getenv("SMTP2_PASSWORD")
-    }
-]
-
-smtp_index = 0
-
-def get_next_smtp():
-    global smtp_index
-    smtp = SMTP_ACCOUNTS[smtp_index]
-    smtp_index = (smtp_index + 1) % len(SMTP_ACCOUNTS)
-    return smtp
-
-@app.route("/send", methods=["POST"])
-def send_email():
+from flask import Flask, g, jsonify, request, send_from_directory
+from werkzeug.security import check_password_hash, generate_password_hash
+
+BASE_DIR = os.path.dirname(os.path.abspath(__file__))
+DB_PATH = os.path.join(BASE_DIR, "messenger.db")
+SESSION_TTL_DAYS = int(os.getenv("SESSION_TTL_DAYS", "30"))
+
+app = Flask(__name__, static_folder="static", static_url_path="/static")
+
+
+# ---------- DB ----------
+def get_db():
+    if "db" not in g:
+        g.db = sqlite3.connect(DB_PATH)
+        g.db.row_factory = sqlite3.Row
+        g.db.execute("PRAGMA foreign_keys = ON")
+    return g.db
+
+
+@app.teardown_appcontext
+def close_db(_error):
+    db = g.pop("db", None)
+    if db is not None:
+        db.close()
+
+
+def now_iso() -> str:
+    return datetime.utcnow().isoformat() + "Z"
+
+
+def parse_iso_z(value: str) -> datetime:
+    return datetime.fromisoformat(value.replace("Z", ""))
+
+
+def table_columns(db: sqlite3.Connection, table_name: str) -> set[str]:
+    rows = db.execute(f"PRAGMA table_info({table_name})").fetchall()
+    return {row["name"] for row in rows}
+
+
+def init_db():
+    db = sqlite3.connect(DB_PATH)
+    db.row_factory = sqlite3.Row
+    cur = db.cursor()
+
+    cur.execute(
+        """
+        CREATE TABLE IF NOT EXISTS users (
+            id INTEGER PRIMARY KEY AUTOINCREMENT,
+            phone TEXT UNIQUE NOT NULL,
+            username TEXT UNIQUE,
+            name TEXT NOT NULL,
+            password_hash TEXT NOT NULL,
+            created_at TEXT NOT NULL,
+            last_seen_at TEXT NOT NULL DEFAULT ''
+        )
+        """
+    )
+
+    cur.execute(
+        """
+        CREATE TABLE IF NOT EXISTS privacy_settings (
+            user_id INTEGER PRIMARY KEY,
+            phone_visibility TEXT NOT NULL DEFAULT 'contacts',
+            last_seen_visibility TEXT NOT NULL DEFAULT 'contacts',
+            allow_invites TEXT NOT NULL DEFAULT 'everyone',
+            FOREIGN KEY (user_id) REFERENCES users(id)
+        )
+        """
+    )
+
+    cur.execute(
+        """
+        CREATE TABLE IF NOT EXISTS sessions (
+            token TEXT PRIMARY KEY,
+            user_id INTEGER NOT NULL,
+            created_at TEXT NOT NULL,
+            expires_at TEXT NOT NULL,
+            FOREIGN KEY (user_id) REFERENCES users(id)
+        )
+        """
+    )
+
+    cur.execute(
+        """
+        CREATE TABLE IF NOT EXISTS chats (
+            id INTEGER PRIMARY KEY AUTOINCREMENT,
+            title TEXT NOT NULL,
+            owner_id INTEGER NOT NULL,
+            invite_code TEXT UNIQUE NOT NULL,
+            created_at TEXT NOT NULL,
+            FOREIGN KEY (owner_id) REFERENCES users(id)
+        )
+        """
+    )
+
+    cur.execute(
+        """
+        CREATE TABLE IF NOT EXISTS chat_members (
+            chat_id INTEGER NOT NULL,
+            user_id INTEGER NOT NULL,
+            joined_at TEXT NOT NULL,
+            nickname TEXT,
+            PRIMARY KEY (chat_id, user_id),
+            FOREIGN KEY (chat_id) REFERENCES chats(id),
+            FOREIGN KEY (user_id) REFERENCES users(id)
+        )
+        """
+    )
+
+    cur.execute(
+        """
+        CREATE TABLE IF NOT EXISTS messages (
+            id INTEGER PRIMARY KEY AUTOINCREMENT,
+            chat_id INTEGER NOT NULL,
+            sender_id INTEGER NOT NULL,
+            text TEXT NOT NULL,
+            is_secret INTEGER NOT NULL DEFAULT 0,
+            ttl_seconds INTEGER,
+            expires_at TEXT,
+            created_at TEXT NOT NULL,
+            FOREIGN KEY (chat_id) REFERENCES chats(id),
+            FOREIGN KEY (sender_id) REFERENCES users(id)
+        )
+        """
+    )
+
+    # Lightweight migrations for existing DB
+    user_cols = table_columns(db, "users")
+    if "username" not in user_cols:
+        cur.execute("ALTER TABLE users ADD COLUMN username TEXT UNIQUE")
+    if "last_seen_at" not in user_cols:
+        cur.execute("ALTER TABLE users ADD COLUMN last_seen_at TEXT NOT NULL DEFAULT ''")
+
+    chat_cols = table_columns(db, "chats")
+    if "invite_code" not in chat_cols:
+        cur.execute("ALTER TABLE chats ADD COLUMN invite_code TEXT")
+        rows = cur.execute("SELECT id FROM chats").fetchall()
+        for row in rows:
+            cur.execute(
+                "UPDATE chats SET invite_code = ? WHERE id = ?",
+                (secrets.token_urlsafe(8), row["id"]),
+            )
+
+    message_cols = table_columns(db, "messages")
+    if "is_secret" not in message_cols:
+        cur.execute("ALTER TABLE messages ADD COLUMN is_secret INTEGER NOT NULL DEFAULT 0")
+    if "ttl_seconds" not in message_cols:
+        cur.execute("ALTER TABLE messages ADD COLUMN ttl_seconds INTEGER")
+    if "expires_at" not in message_cols:
+        cur.execute("ALTER TABLE messages ADD COLUMN expires_at TEXT")
+
+    session_cols = table_columns(db, "sessions")
+    if "expires_at" not in session_cols:
+        cur.execute("ALTER TABLE sessions ADD COLUMN expires_at TEXT")
+        cur.execute(
+            "UPDATE sessions SET expires_at = ? WHERE expires_at IS NULL OR expires_at = ''",
+            ((datetime.utcnow() + timedelta(days=SESSION_TTL_DAYS)).isoformat() + "Z",),
+        )
+
+    # Ensure every user has privacy settings
+    user_ids = cur.execute("SELECT id FROM users").fetchall()
+    for row in user_ids:
+        cur.execute(
+            """
+            INSERT OR IGNORE INTO privacy_settings (user_id)
+            VALUES (?)
+            """,
+            (row["id"],),
+        )
+
+    db.commit()
+    db.close()
+
+
+# ---------- Auth ----------
+def auth_required(handler):
+    @wraps(handler)
+    def wrapper(*args, **kwargs):
+        auth_header = request.headers.get("Authorization", "")
+        if not auth_header.startswith("Bearer "):
+            return jsonify({"error": "Missing bearer token"}), 401
+
+        token = auth_header.split(" ", 1)[1]
+        db = get_db()
+        row = db.execute(
+            """
+            SELECT users.id, users.phone, users.username, users.name, sessions.expires_at
+            FROM sessions
+            JOIN users ON users.id = sessions.user_id
+            WHERE sessions.token = ?
+            """,
+            (token,),
+        ).fetchone()
+        if not row:
+            return jsonify({"error": "Invalid session"}), 401
+        if parse_iso_z(row["expires_at"]) <= datetime.utcnow():
+            db.execute("DELETE FROM sessions WHERE token = ?", (token,))
+            db.commit()
+            return jsonify({"error": "Session expired"}), 401
+
+        db.execute("UPDATE users SET last_seen_at = ? WHERE id = ?", (now_iso(), row["id"]))
+        db.commit()
+
+        g.current_user = row
+        return handler(*args, **kwargs)
+
+    return wrapper
+
+
+def is_user_in_chat(db, user_id: int, chat_id: int) -> bool:
+    row = db.execute(
+        "SELECT 1 FROM chat_members WHERE chat_id = ? AND user_id = ?",
+        (chat_id, user_id),
+    ).fetchone()
+    return bool(row)
+
+
+def can_view_field(viewer_id: int, owner_id: int, policy: str, same_chat: bool) -> bool:
+    if viewer_id == owner_id:
+        return True
+    if policy == "everyone":
+        return True
+    if policy == "nobody":
+        return False
+    # contacts model approximated as "share at least one chat"
+    return same_chat
+
+
+def prune_expired_messages(db):
+    now = now_iso()
+    db.execute(
+        "DELETE FROM messages WHERE is_secret = 1 AND expires_at IS NOT NULL AND expires_at <= ?",
+        (now,),
+    )
+    db.commit()
+
+
+def prune_expired_sessions(db):
+    db.execute("DELETE FROM sessions WHERE expires_at <= ?", (now_iso(),))
+    db.commit()
+
+
+# ---------- API ----------
+@app.route("/")
+def index():
+    return send_from_directory("static", "index.html")
+
+
+@app.route("/api/health")
+def health():
+    return jsonify({"status": "ok", "version": "v2"})
+
+
+@app.route("/api/auth/register", methods=["POST"])
+def register():
+    payload = request.get_json(silent=True) or {}
+    phone = (payload.get("phone") or "").strip()
+    name = (payload.get("name") or "").strip()
+    username = (payload.get("username") or "").strip().lower()
+    password = payload.get("password") or ""
+
+    if not phone or not name or len(password) < 6:
+        return jsonify({"error": "phone, name and password>=6 required"}), 400
+
+    if username and (len(username) < 4 or not username.replace("_", "").isalnum()):
+        return jsonify({"error": "username invalid (min 4, letters/digits/_ )"}), 400
+
+    db = get_db()
     try:
-        data = request.form
-        files = request.files
+        cursor = db.execute(
+            """
+            INSERT INTO users (phone, username, name, password_hash, created_at, last_seen_at)
+            VALUES (?, ?, ?, ?, ?, ?)
+            """,
+            (phone, username or None, name, generate_password_hash(password), now_iso(), now_iso()),
+        )
+        user_id = cursor.lastrowid
+        db.execute("INSERT INTO privacy_settings (user_id) VALUES (?)", (user_id,))
+        db.commit()
+    except sqlite3.IntegrityError:
+        return jsonify({"error": "phone or username already exists"}), 409
+
+    return jsonify({"status": "registered"}), 201
+
+
+@app.route("/api/auth/login", methods=["POST"])
+def login():
+    payload = request.get_json(silent=True) or {}
+    phone_or_username = (payload.get("phone") or payload.get("username") or "").strip().lower()
+    password = payload.get("password") or ""
+
+    db = get_db()
+    user = db.execute(
+        """
+        SELECT * FROM users
+        WHERE lower(phone) = ? OR lower(COALESCE(username, '')) = ?
+        """,
+        (phone_or_username, phone_or_username),
+    ).fetchone()
+
+    if not user or not check_password_hash(user["password_hash"], password):
+        return jsonify({"error": "Invalid credentials"}), 401
+
+    token = secrets.token_urlsafe(32)
+    expires_at = (datetime.utcnow() + timedelta(days=SESSION_TTL_DAYS)).isoformat() + "Z"
+    db.execute(
+        "INSERT INTO sessions (token, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)",
+        (token, user["id"], now_iso(), expires_at),
+    )
+    db.execute("UPDATE users SET last_seen_at = ? WHERE id = ?", (now_iso(), user["id"]))
+    prune_expired_sessions(db)
+    db.commit()
+
+    return jsonify(
+        {
+            "token": token,
+            "expires_at": expires_at,
+            "user": {
+                "id": user["id"],
+                "phone": user["phone"],
+                "username": user["username"],
+                "name": user["name"],
+            },
+        }
+    )
+
+
+@app.route("/api/auth/logout", methods=["POST"])
+@auth_required
+def logout():
+    auth_header = request.headers.get("Authorization", "")
+    token = auth_header.split(" ", 1)[1]
+    db = get_db()
+    db.execute("DELETE FROM sessions WHERE token = ?", (token,))
+    db.commit()
+    return jsonify({"status": "logged_out"})
+
+
+@app.route("/api/privacy", methods=["GET"])
+@auth_required
+def get_privacy():
+    db = get_db()
+    row = db.execute(
+        "SELECT phone_visibility, last_seen_visibility, allow_invites FROM privacy_settings WHERE user_id = ?",
+        (g.current_user["id"],),
+    ).fetchone()
+    return jsonify(dict(row))
+
+
+@app.route("/api/privacy", methods=["PUT"])
+@auth_required
+def update_privacy():
+    payload = request.get_json(silent=True) or {}
+    allowed = {"everyone", "contacts", "nobody"}
+    phone_visibility = payload.get("phone_visibility")
+    last_seen_visibility = payload.get("last_seen_visibility")
+    allow_invites = payload.get("allow_invites")
+
+    if phone_visibility and phone_visibility not in allowed:
+        return jsonify({"error": "phone_visibility invalid"}), 400
+    if last_seen_visibility and last_seen_visibility not in allowed:
+        return jsonify({"error": "last_seen_visibility invalid"}), 400
+    if allow_invites and allow_invites not in allowed:
+        return jsonify({"error": "allow_invites invalid"}), 400
+
+    db = get_db()
+    current = db.execute(
+        "SELECT phone_visibility, last_seen_visibility, allow_invites FROM privacy_settings WHERE user_id = ?",
+        (g.current_user["id"],),
+    ).fetchone()
+
+    db.execute(
+        """
+        UPDATE privacy_settings
+        SET phone_visibility = ?, last_seen_visibility = ?, allow_invites = ?
+        WHERE user_id = ?
+        """,
+        (
+            phone_visibility or current["phone_visibility"],
+            last_seen_visibility or current["last_seen_visibility"],
+            allow_invites or current["allow_invites"],
+            g.current_user["id"],
+        ),
+    )
+    db.commit()
+    return jsonify({"status": "updated"})
+
+
+@app.route("/api/chats", methods=["GET"])
+@auth_required
+def list_chats():
+    db = get_db()
+    prune_expired_messages(db)
+    rows = db.execute(
+        """
+        SELECT chats.id, chats.title, chats.invite_code, chats.created_at
+        FROM chats
+        JOIN chat_members ON chat_members.chat_id = chats.id
+        WHERE chat_members.user_id = ?
+        ORDER BY chats.id DESC
+        """,
+        (g.current_user["id"],),
+    ).fetchall()
+    return jsonify([dict(row) for row in rows])
+
+
+@app.route("/api/chats", methods=["POST"])
+@auth_required
+def create_chat():
+    payload = request.get_json(silent=True) or {}
+    title = (payload.get("title") or "").strip()
+    participant = (payload.get("participant") or "").strip().lower()  # phone or username
+
+    if not title:
+        return jsonify({"error": "title required"}), 400
+
+    db = get_db()
+    invite_code = secrets.token_urlsafe(8)
+    cursor = db.execute(
+        "INSERT INTO chats (title, owner_id, invite_code, created_at) VALUES (?, ?, ?, ?)",
+        (title, g.current_user["id"], invite_code, now_iso()),
+    )
+    chat_id = cursor.lastrowid
+
+    db.execute(
+        "INSERT INTO chat_members (chat_id, user_id, joined_at) VALUES (?, ?, ?)",
+        (chat_id, g.current_user["id"], now_iso()),
+    )
+
+    if participant:
+        target = db.execute(
+            "SELECT id FROM users WHERE lower(phone) = ? OR lower(COALESCE(username, '')) = ?",
+            (participant, participant),
+        ).fetchone()
+        if not target:
+            db.rollback()
+            return jsonify({"error": "participant not found"}), 404
+
+        privacy = db.execute(
+            "SELECT allow_invites FROM privacy_settings WHERE user_id = ?",
+            (target["id"],),
+        ).fetchone()
+        if privacy and privacy["allow_invites"] == "nobody":
+            db.rollback()
+            return jsonify({"error": "participant disallows invites"}), 403
+
+        db.execute(
+            "INSERT INTO chat_members (chat_id, user_id, joined_at) VALUES (?, ?, ?)",
+            (chat_id, target["id"], now_iso()),
+        )
+
+    db.commit()
+    return jsonify({"id": chat_id, "title": title, "invite_code": invite_code}), 201
+
+
+@app.route("/api/chats/join", methods=["POST"])
+@auth_required
+def join_chat():
+    payload = request.get_json(silent=True) or {}
+    invite_code = (payload.get("invite_code") or "").strip()
+    if not invite_code:
+        return jsonify({"error": "invite_code required"}), 400
+
+    db = get_db()
+    chat = db.execute("SELECT id FROM chats WHERE invite_code = ?", (invite_code,)).fetchone()
+    if not chat:
+        return jsonify({"error": "invalid invite_code"}), 404
+
+    db.execute(
+        "INSERT OR IGNORE INTO chat_members (chat_id, user_id, joined_at) VALUES (?, ?, ?)",
+        (chat["id"], g.current_user["id"], now_iso()),
+    )
+    db.commit()
+    return jsonify({"status": "joined", "chat_id": chat["id"]})
+
+
+@app.route("/api/chats/<int:chat_id>/messages", methods=["GET"])
+@auth_required
+def get_messages(chat_id: int):
+    db = get_db()
+    prune_expired_messages(db)
+
+    if not is_user_in_chat(db, g.current_user["id"], chat_id):
+        return jsonify({"error": "Access denied"}), 403
+
+    limit = request.args.get("limit", type=int) or 100
+    limit = max(1, min(limit, 300))
+    before_id = request.args.get("before_id", type=int)
+
+    query = """
+        SELECT
+            m.id, m.text, m.created_at, m.is_secret, m.ttl_seconds, m.expires_at,
+            u.id AS sender_id, u.name AS sender_name, u.phone AS sender_phone, u.username AS sender_username,
+            p.phone_visibility, p.last_seen_visibility, u.last_seen_at
+        FROM messages m
+        JOIN users u ON u.id = m.sender_id
+        JOIN privacy_settings p ON p.user_id = u.id
+        WHERE m.chat_id = ?
+    """
+    params: list[object] = [chat_id]
+    if before_id:
+        query += " AND m.id < ?"
+        params.append(before_id)
+    query += " ORDER BY m.id DESC LIMIT ?"
+    params.append(limit)
+
+    rows = db.execute(query, params).fetchall()
+
+    response = []
+    for row in rows:
+        same_chat = True
+        phone_visible = can_view_field(
+            g.current_user["id"], row["sender_id"], row["phone_visibility"], same_chat
+        )
+        last_seen_visible = can_view_field(
+            g.current_user["id"], row["sender_id"], row["last_seen_visibility"], same_chat
+        )
+
+        response.append(
+            {
+                "id": row["id"],
+                "text": row["text"],
+                "created_at": row["created_at"],
+                "is_secret": bool(row["is_secret"]),
+                "ttl_seconds": row["ttl_seconds"],
+                "expires_at": row["expires_at"],
+                "sender": {
+                    "id": row["sender_id"],
+                    "name": row["sender_name"],
+                    "username": row["sender_username"],
+                    "phone": row["sender_phone"] if phone_visible else None,
+                    "last_seen_at": row["last_seen_at"] if last_seen_visible else None,
+                },
+            }
+        )
+
+    response.reverse()
+    return jsonify(response)
+
+
+@app.route("/api/chats/<int:chat_id>/messages", methods=["POST"])
+@auth_required
+def create_message(chat_id: int):
+    payload = request.get_json(silent=True) or {}
+    text = (payload.get("text") or "").strip()
+    is_secret = bool(payload.get("is_secret", False))
+    ttl_seconds = payload.get("ttl_seconds")
 
-        recipient = data["recipient"]
-        subject = data["subject"]
-        message = data["message"]
+    if not text:
+        return jsonify({"error": "text required"}), 400
 
-        smtp = get_next_smtp()
+    if is_secret:
+        if not isinstance(ttl_seconds, int) or ttl_seconds < 5 or ttl_seconds > 86400:
+            return jsonify({"error": "ttl_seconds required for secret messages (5..86400)"}), 400
 
-        msg = MIMEMultipart()
-        msg["From"] = smtp["login"]
-        msg["To"] = recipient
-        msg["Subject"] = subject
-        msg.attach(MIMEApplication(message.encode(), Name="message.txt"))
+    db = get_db()
+    if not is_user_in_chat(db, g.current_user["id"], chat_id):
+        return jsonify({"error": "Access denied"}), 403
 
-        for file_key in files:
-            file = files[file_key]
-            part = MIMEApplication(file.read(), Name=file.filename)
-            part["Content-Disposition"] = f'attachment; filename="{file.filename}"'
-            msg.attach(part)
+    expires_at = None
+    if is_secret:
+        expires_at = (datetime.utcnow() + timedelta(seconds=ttl_seconds)).isoformat() + "Z"
 
-        with smtplib.SMTP_SSL(smtp["host"], smtp["port"]) as server:
-            server.login(smtp["login"], smtp["password"])
-            server.sendmail(smtp["login"], recipient, msg.as_string())
+    cursor = db.execute(
+        """
+        INSERT INTO messages (chat_id, sender_id, text, is_secret, ttl_seconds, expires_at, created_at)
+        VALUES (?, ?, ?, ?, ?, ?, ?)
+        """,
+        (chat_id, g.current_user["id"], text, int(is_secret), ttl_seconds, expires_at, now_iso()),
+    )
+    db.commit()
 
-        with open("logs.txt", "a") as log:
-            log.write(f"{recipient} | {subject}\n")
+    return (
+        jsonify(
+            {
+                "id": cursor.lastrowid,
+                "chat_id": chat_id,
+                "text": text,
+                "is_secret": is_secret,
+                "ttl_seconds": ttl_seconds,
+                "expires_at": expires_at,
+                "created_at": now_iso(),
+            }
+        ),
+        201,
+    )
 
-        return jsonify({"status": "ok", "message": "Email sent"})
-    except Exception as e:
-        return jsonify({"status": "error", "message": str(e)})
 
 if __name__ == "__main__":
-    port = int(os.environ.get("PORT", 5000))
-    app.run(host="0.0.0.0", port=port)
\ No newline at end of file
+    init_db()
+    app.run(
+        host="0.0.0.0",
+        port=int(os.getenv("PORT", 5000)),
+        debug=os.getenv("FLASK_DEBUG", "0") == "1",
+    )
+else:
+    init_db()
