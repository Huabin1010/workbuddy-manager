"""桌面窗口免登录：只有本机壳子带的密钥能进，浏览器同一地址仍要登录。"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from starlette.requests import Request  # noqa: E402

from server import config, security  # noqa: E402

TOKEN = 'desk-secret-token'


def _req(*, host: str | None, header: str | None = None, cookie: str | None = None) -> Request:
    headers = []
    if header is not None:
        headers.append((b'x-workbuddy-desktop', header.encode()))
    if cookie is not None:
        headers.append((b'cookie', f'wb_desktop={cookie}'.encode()))
    scope = {
        'type': 'http',
        'method': 'GET',
        'path': '/api/me',
        'headers': headers,
        'query_string': b'',
    }
    if host is not None:
        scope['client'] = (host, 12345)
    return Request(scope)


class DesktopAuthTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        path = Path(self._tmp.name) / 'users.json'
        path.write_text(json.dumps({
            'secret': 'S' * 64,
            'users': [
                {'username': 'guest', 'role': 'viewer', 'pwd_hash': 'x'},
                {'username': 'admin', 'role': 'admin', 'pwd_hash': 'y'},
            ],
            'epoch': 1,
        }), encoding='utf-8')
        self._orig = config.USERS_FILE
        config.USERS_FILE = path
        self._env = os.environ.get('WB_DESKTOP_TOKEN')
        os.environ['WB_DESKTOP_TOKEN'] = TOKEN

    def tearDown(self) -> None:
        config.USERS_FILE = self._orig
        if self._env is None:
            os.environ.pop('WB_DESKTOP_TOKEN', None)
        else:
            os.environ['WB_DESKTOP_TOKEN'] = self._env
        self._tmp.cleanup()

    def test_loopback_header_is_admin(self) -> None:
        user = security.current_user(_req(host='127.0.0.1', header=TOKEN))
        self.assertEqual(user['username'], 'admin')
        self.assertEqual(user['role'], 'admin')

    def test_loopback_cookie_is_admin(self) -> None:
        user = security.current_user(_req(host='::1', cookie=TOKEN))
        self.assertEqual(user['username'], 'admin')

    def test_wrong_secret_rejected(self) -> None:
        with self.assertRaises(Exception) as ctx:
            security.current_user(_req(host='127.0.0.1', header='nope'))
        self.assertIn('未登录', str(ctx.exception))

    def test_missing_secret_rejected(self) -> None:
        with self.assertRaises(Exception):
            security.current_user(_req(host='127.0.0.1'))

    def test_remote_peer_rejected(self) -> None:
        with self.assertRaises(Exception):
            security.current_user(_req(host='203.0.113.8', header=TOKEN))

    def test_unset_env_rejected(self) -> None:
        os.environ['WB_DESKTOP_TOKEN'] = ''
        with self.assertRaises(Exception):
            security.current_user(_req(host='127.0.0.1', header=TOKEN))


if __name__ == '__main__':
    unittest.main()
