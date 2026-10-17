"""Product identity fixtures using the stock host's actual daemon harness.

No implementation modules are imported. Human actions use the daemon-token
HTTP service; model actions are native provider tool calls.
"""

import json
import sqlite3

from harness import Albedo, Reply, operation_id

SERVICE = "/extensions/personality"
PROTOCOLS = ("responses", "chat_completions")


def app(provider, protocol="responses", *, installed=True):
    # Host "enabled" settings are global selection defaults, including the
    # human service. Tests of ordinary sessions disable personality per session.
    return Albedo(
        provider,
        protocol=protocol,
        prepare=lambda instance: instance.write_extensions(
            {"enabled": {"personality": installed}}
        ),
    )


def read(instance, route):
    with instance.api(route) as response:
        return json.load(response)


def value(instance, path, body=None, *, method=None):
    with instance.api(SERVICE + path, body, method=method) as response:
        return json.load(response)


def setup(instance, session, content="Initial identity", *, retry_key=None):
    return value(
        instance,
        f"/sessions/{session}/setup",
        {
            "name": "Personal agent",
            "content": content,
            "retry_key": retry_key or operation_id(),
        },
    )


def inspect(instance, session):
    return value(instance, f"/sessions/{session}")


def bind(instance, session, persona=None):
    current = inspect(instance, session)
    body = {
        "expected_generation": current["binding_generation"],
        "acknowledge_history_through": current["pre_binding_history"]["through"],
    }
    if persona is not None:
        body["persona_id"] = persona
    return value(instance, f"/sessions/{session}/binding", body)


def write(instance, session, content, *, expected_revision=None, retry_key=None):
    if expected_revision is None:
        expected_revision = value(instance, f"/sessions/{session}/document")["revision"]
    return value(
        instance,
        f"/sessions/{session}/document",
        {
            "content": content,
            "expected_revision": expected_revision,
            "retry_key": retry_key or operation_id(),
        },
    )


def select(instance, session, **extensions):
    route = f"/sessions/{session}?view=configuration"
    with instance.api(route) as response:
        etag = response.headers["ETag"]
        response.read()
    with instance.api(
        route,
        {"selection": {"extensions": extensions}},
        method="PATCH",
        headers={"If-Match": etag},
    ) as response:
        return json.load(response)


def captured_identity(summary):
    """Read the actual P1 inspector object and require its mandatory block."""
    context = summary["request_context"]
    captures = [item for item in context["captures"] if item["owner"] == "personality"]
    assert len(captures) == 1, captures
    included = [item for item in context["included"] if item["owner"] == "personality"]
    assert len(included) == 1, included
    assert included[0]["name"] == "personality identity", included
    assert included[0]["mandatory"] is True, included
    assert included[0]["kind"] == "instructions", included
    assert included[0]["snapshot_id"] == captures[0]["snapshot_id"], context
    return captures[0]


def delete(instance, session, *, subtree=False):
    route = f"/sessions/{session}?view=configuration"
    with instance.api(route) as response:
        etag = response.headers["ETag"]
        current = json.load(response)
    if subtree:
        route += "&scope=subtree&family_revision=" + current["family_revision"]
    with instance.api(route, method="DELETE", headers={"If-Match": etag}) as response:
        return json.load(response)


def tool(name, **arguments):
    return Reply("python", tool_name=name, tool_arguments=arguments)


def instructions(request):
    if "instructions" in request:
        return request["instructions"]
    return "\n\n".join(
        message["content"]
        for message in request["messages"]
        if message.get("role") == "system"
    )


def identity(request):
    prefix, block = instructions(request).split("\n\n[request context: ", 1)
    label, payload = block.split("\n", 1)
    metadata, content = payload.split("\n", 1)
    captured = json.loads(metadata)
    captured["document"] = content.split("\n\n", 1)[1]
    captured["snapshot_id"] = label.split("; snapshot ", 1)[1].removesuffix("]")
    return prefix, captured


def tool_names(request):
    return {
        entry.get("name", entry.get("function", {}).get("name"))
        for entry in request.get("tools", [])
    }


def tool_results(request):
    if "input" in request:
        return [
            json.loads(entry["output"])
            for entry in request["input"]
            if entry.get("type") == "function_call_output"
        ]
    return [
        json.loads(entry["content"])
        for entry in request["messages"]
        if entry.get("role") == "tool"
    ]


def rows(instance, sql, parameters=()):
    with sqlite3.connect(instance.home / "albedo.sqlite") as db:
        return db.execute(sql, parameters).fetchall()


def spawn(instance, parent, name, *, child=None, input_id=None):
    child, input_id = child or operation_id(), input_id or operation_id()
    with instance.api(
        f"/sessions/{child}",
        {
            "kind": "child",
            "parent_id": parent,
            "address": name,
            "name": name,
            "initial_input_id": input_id,
            "task": "Inspect only the explicitly supplied HTTP-TASK goal.",
        },
        method="PUT",
        headers={"If-None-Match": "*"},
    ) as response:
        resource = json.load(response)
    assert (resource["id"], resource["parent_id"]) == (child, parent), resource
    return child, input_id


def fork(instance, parent, checkpoint, *, child=None):
    child = child or operation_id()
    with instance.api(
        f"/sessions/{child}",
        {
            "kind": "fork",
            "source_session_id": parent,
            "checkpoint_id": checkpoint,
        },
        method="PUT",
        headers={"If-None-Match": "*"},
    ) as response:
        resource = json.load(response)
    assert resource["id"] == child, resource
    return child
