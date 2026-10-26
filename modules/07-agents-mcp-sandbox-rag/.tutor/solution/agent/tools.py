"""GIVEN - do not edit. The tools the agent can use."""
import json
import os

_DEFAULT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tickets.json")


def lookup_ticket(ticket_id: str) -> str:
    """Return the record of a support ticket, for example 'status=open owner=ops nonce=ab12cd34ef56'."""
    with open(os.environ.get("TICKETS_JSON", _DEFAULT)) as f:
        data = json.load(f)
    if ticket_id not in data:
        return f"error: unknown ticket {ticket_id}"
    return str(data[ticket_id])


TOOL_FUNCS = {"lookup_ticket": lookup_ticket}
