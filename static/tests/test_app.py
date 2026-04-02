import os
import tempfile
import unittest


class MessengerApiTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        os.environ["SESSION_TTL_DAYS"] = "30"

        import app as messenger_app

        self.messenger_app = messenger_app
        self.messenger_app.DB_PATH = os.path.join(self.tmpdir.name, "test.db")
        self.messenger_app.init_db()
        self.client = self.messenger_app.app.test_client()

    def tearDown(self):
        self.tmpdir.cleanup()

    def _register_and_login(self, phone, username, name):
        r = self.client.post(
            "/api/auth/register",
            json={"phone": phone, "username": username, "name": name, "password": "secret1"},
        )
        self.assertEqual(r.status_code, 201)
        login = self.client.post(
            "/api/auth/login",
            json={"phone": username, "password": "secret1"},
        )
        self.assertEqual(login.status_code, 200)
        return login.json["token"]

    def test_secret_ttl_and_pagination(self):
        token = self._register_and_login("+70000001001", "alice_test", "Alice")
        headers = {"Authorization": f"Bearer {token}"}

        chat = self.client.post("/api/chats", json={"title": "Room"}, headers=headers)
        self.assertEqual(chat.status_code, 201)
        chat_id = chat.json["id"]

        for i in range(4):
            m = self.client.post(
                f"/api/chats/{chat_id}/messages",
                json={"text": f"msg-{i}"},
                headers=headers,
            )
            self.assertEqual(m.status_code, 201)

        page = self.client.get(f"/api/chats/{chat_id}/messages?limit=2", headers=headers)
        self.assertEqual(page.status_code, 200)
        self.assertEqual(len(page.json), 2)
        oldest_seen = page.json[0]["id"]

        page2 = self.client.get(
            f"/api/chats/{chat_id}/messages?before_id={oldest_seen}&limit=10", headers=headers
        )
        self.assertEqual(page2.status_code, 200)
        self.assertGreaterEqual(len(page2.json), 1)

    def test_logout_revokes_token(self):
        token = self._register_and_login("+70000001002", "bob_test", "Bob")
        headers = {"Authorization": f"Bearer {token}"}

        me = self.client.get("/api/privacy", headers=headers)
        self.assertEqual(me.status_code, 200)

        out = self.client.post("/api/auth/logout", headers=headers)
        self.assertEqual(out.status_code, 200)

        me_after = self.client.get("/api/privacy", headers=headers)
        self.assertEqual(me_after.status_code, 401)


if __name__ == "__main__":
    unittest.main()
