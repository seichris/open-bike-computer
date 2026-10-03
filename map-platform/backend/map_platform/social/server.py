"""Optional independently scaled social API at the shared public path."""
from fastapi import FastAPI
from .api import create_app


def app():
    root = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    root.mount('/v1/social', create_app())
    return root
