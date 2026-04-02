import os
import tempfile
import unittest

from app import app, init_db


class MessengerApiTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.original_db_path = app.config.get("DATABASE")
        self.test_db_path = os.path.join(self.tempdir.name, "test_messenger.db")
        app.config["TESTING"] = True
        app.config["DATABASE"] = self.test_db_path

        import app as app_module

        self.original_module_db_path = app_module.DB_PATH
        app_module.DB_PATH = self.test_db_path

        if os.path.exists(self.test_db_path):
            os.remove(self.test_db_path)
        init_db()
        self.client = app.test_client()

    def tearDown(self):
        import app as app_module

        app_module.DB_PATH = self.original_module_db_path
        if self.original_db_path is not None:
            app.config["DATABASE"] = self.original_db_path
        self.tempdir.cleanup()

    def register_user(self, phone, username, name, password="secret1"):
        return self.client.post(
            "/api/auth/register",
            json={
                "phone": phone,
                "username": username,
                "name": name,
                "password": password,
            },
        )

    def login_user(self, login_value, password="secret1"):
        return self.client.post(
            "/api/auth/login",
            json={"phone": login_value, "password": password},
        )

    def auth_headers(self, token):
        return {"Authorization": f"Bearer {token}"}

    def test_logout_revokes_token(self):
        register = self.register_user("+70000000021", "alice_logout", "Alice")
        self.assertEqual(register.status_code, 201)

        login = self.login_user("alice_logout")
        self.assertEqual(login.status_code, 200)
        token = login.get_json()["token"]

        logout = self.client.post("/api/auth/logout", headers=self.auth_headers(token))
        self.assertEqual(logout.status_code, 200)

        denied = self.client.get("/api/chats", headers=self.auth_headers(token))
        self.assertEqual(denied.status_code, 401)

    def test_message_pagination_before_id(self):
        self.assertEqual(self.register_user("+70000000031", "alice_page", "Alice").status_code, 201)
        self.assertEqual(self.register_user("+70000000032", "bob_page", "Bob").status_code, 201)

        login = self.login_user("alice_page")
        self.assertEqual(login.status_code, 200)
        token = login.get_json()["token"]
        headers = self.auth_headers(token)

        chat = self.client.post(
            "/api/chats",
            json={"title": "Paginated Chat", "participant": "bob_page"},
            headers=headers,
        )
        self.assertEqual(chat.status_code, 201)
        chat_id = chat.get_json()["id"]

        for idx in range(1, 8):
            msg = self.client.post(
                f"/api/chats/{chat_id}/messages",
                json={"text": f"message-{idx}"},
                headers=headers,
            )
            self.assertEqual(msg.status_code, 201)

        latest = self.client.get(
            f"/api/chats/{chat_id}/messages?limit=3",
            headers=headers,
        )
        self.assertEqual(latest.status_code, 200)
        latest_items = latest.get_json()
        self.assertEqual([item["text"] for item in latest_items], ["message-5", "message-6", "message-7"])

        previous = self.client.get(
            f"/api/chats/{chat_id}/messages?limit=3&before_id={latest_items[0]['id']}",
            headers=headers,
        )
        self.assertEqual(previous.status_code, 200)
        previous_items = previous.get_json()
        self.assertEqual([item["text"] for item in previous_items], ["message-2", "message-3", "message-4"])


if __name__ == "__main__":
    unittest.main()
