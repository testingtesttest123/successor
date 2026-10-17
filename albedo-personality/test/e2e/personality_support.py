"""Authenticated free-form personality service helper on the real daemon."""

import json


def value(app, path, body=None, *, method=None):
    with app.api("/extensions/personality" + path, body, method=method) as response:
        return json.load(response)


def create(app, *, content="Initial identity", **configuration):
    return value(
        app,
        "/personas",
        {"name": "Personal agent", "content": content, **configuration},
    )


def inspect(app, session):
    return value(app, f"/sessions/{session}")


def bind(app, session, persona):
    current = inspect(app, session)
    return value(
        app,
        f"/sessions/{session}/binding",
        {
            "persona_id": persona,
            "expected_generation": (current["binding"] or {}).get("generation", 0),
            "acknowledge_history_through": current["pre_binding_history"]["through"],
        },
    )
