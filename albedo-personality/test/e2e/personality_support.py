"""Small real-daemon helpers for explicit human personality setup."""

import json

from harness import operation_id

MOUNT = "/extensions/personality"


def value(app, path, body=None, *, method=None):
    with app.api(MOUNT + path, body, method=method) as response:
        return json.load(response)


def enable(app, session, enabled=True):
    route = f"/sessions/{session}?view=configuration"
    with app.api(route) as response:
        response.read()
        revision = response.headers["ETag"]
    app.api(
        route,
        {"selection": {"extensions": {"personality": enabled}}},
        method="PATCH",
        headers={"If-Match": revision},
    ).close()


def create(app, *, default=False, operation=None, **configuration):
    return value(
        app,
        "/personas",
        {
            "operation_id": operation or operation_id(),
            "name": "Personal agent",
            "make_default": default,
            **configuration,
        },
    )


def inspect(app, session):
    return value(app, f"/sessions/{session}")


def bind(app, session, persona=None):
    disclosure = inspect(app, session)["pre_binding_history"]
    return value(
        app,
        f"/sessions/{session}/binding",
        {
            "operation_id": operation_id(),
            "persona_id": persona,
            "use_default": persona is None,
            "expected_binding_revision": inspect(app, session)["binding_revision"],
            "acknowledge_history_through": disclosure["through"],
        },
    )


def page_action(app, session, action_id, form=None):
    """Execute the exact declared human page operation, as a generic client does."""
    page = inspect(app, session)["page"]
    action = next(action for action in page["actions"] if action["id"] == action_id)
    operation = action["operation"]
    body = {}
    for pointer, binding in operation["body"].items():
        assert pointer.count("/") == 1, pointer
        if binding["source"] == "literal":
            body[pointer[1:]] = binding["value"]
        else:
            assert binding["source"] == "form", binding
            body[pointer[1:]] = (form or {})[binding["pointer"][1:]]
    with app.api(
        operation["path_template"], body, method=operation["method"]
    ) as response:
        return json.load(response)
