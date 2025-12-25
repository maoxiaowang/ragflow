import asyncio

from flask.sessions import SecureCookieSession
from itsdangerous import want_bytes
from quart import Quart
from quart.wrappers.response import FileBody, Response
from quart_session.sessions import SessionInterface, RedisSession

from rag.utils.redis_conn import REDIS_CONN


class ValkeyRedisSessionInterface(SessionInterface):
    session_class = RedisSession

    def __init__(self, key_prefix="ragflow_session:", use_signer=True, permanent=False, **kwargs):
        super().__init__(key_prefix=key_prefix, use_signer=use_signer, permanent=permanent, **kwargs)
        self.backend = REDIS_CONN.REDIS

    async def create(self, app: Quart):
        pass

    async def get(self, key: str, app: Quart = None):
        return await asyncio.to_thread(self.backend.get, key)

    async def set(self, key: str, value, expiry: int = None, app: Quart = None):
        return await asyncio.to_thread(self.backend.set, key, value, expiry or 3600)

    async def delete(self, key: str, app: Quart = None):
        return await asyncio.to_thread(self.backend.delete, key)

    async def save_session(  # type: ignore
        self,
        app: "Quart",
        session: SecureCookieSession,
        response: Response
    ) -> None:
        # prevent set-cookie on unmodified session objects
        if not session.modified:
            return

        # prevent set-cookie on (static) file responses
        # https://github.com/fengsp/flask-session/pull/70
        if self._config['SESSION_STATIC_FILE'] is False and \
                isinstance(response.response, FileBody):
            return

        cname = app.config.get('SESSION_COOKIE_NAME', 'session')
        session_key = self.key_prefix + session.sid
        domain = self.get_cookie_domain(app)
        path = self.get_cookie_path(app)
        if not session:
            if session.modified:
                await self.delete(key=session_key, app=app)
                response.delete_cookie(cname,
                                       domain=domain, path=path)
            return
        httponly = self.get_cookie_httponly(app)
        samesite = self.get_cookie_samesite(app)
        secure = self.get_cookie_secure(app)
        expires = self.get_expiration_time(app, session)

        if self.serializer is None:
            val = dict(session)
        else:
            val = self.serializer.dumps(dict(session))

        await self.set(key=session_key, value=val, app=app)
        if self.use_signer:
            session_id = self._get_signer(app).sign(want_bytes(session.sid))
        else:
            session_id = session.sid
        if isinstance(session_id, bytes):
            session_id = session_id.decode('utf-8')

        response.set_cookie(cname, session_id,
                            expires=expires, httponly=httponly,
                            domain=domain, path=path, secure=secure, samesite=samesite)
